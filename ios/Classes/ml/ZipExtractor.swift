import Foundation
import Compression

/// Minimal ZIP archive extractor.
/// No external dependencies. Supports stored and deflated entries.
enum ZipExtractor {

    /// Extract a ZIP archive on disk to a destination directory. Streams via
    /// `FileHandle` + `compression_stream`, so peak resident memory stays
    /// at ~256 KB regardless of archive size. Use this for downloaded model
    /// `.zip`s (up to 150 MB) — see C5.
    static func extract(_ zipURL: URL, to destinationDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // Canonical destination — every entry's resolved path must stay under
        // this prefix (zip-slip defence).
        let destRoot = destinationDir.standardizedFileURL.resolvingSymlinksInPath().path
        let destRootPrefix = destRoot.hasSuffix("/") ? destRoot : destRoot + "/"

        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }

        while true {
            // Local file header is 30 bytes minimum.
            guard let header = try readExact(handle, count: 30) else { break }
            // PK\x03\x04 — local file header signature. Anything else means
            // we've reached the central directory (or EOF).
            guard header[0] == 0x50, header[1] == 0x4B,
                  header[2] == 0x03, header[3] == 0x04 else { break }

            let generalPurpose    = readUInt16(header, at: 6)
            let compressionMethod = readUInt16(header, at: 8)
            let compressedSize    = Int(readUInt32(header, at: 18))
            let filenameLen       = Int(readUInt16(header, at: 26))
            let extraLen          = Int(readUInt16(header, at: 28))

            // Filename + extra fields come immediately after the header.
            guard let nameAndExtra = try readExact(handle, count: filenameLen + extraLen)
            else { break }
            let filenameData = nameAndExtra.prefix(filenameLen)
            let filename = String(data: filenameData, encoding: .utf8) ?? ""

            // Data-descriptor entries (bit 3, sizes only in the trailing
            // descriptor) require scanning forward for the next signature —
            // an O(n) operation incompatible with streaming. Bail out.
            // Our model archives are produced by `zip -X`, which never sets
            // this bit.
            if generalPurpose & 0x08 != 0 && compressedSize == 0 {
                throw ZipError.invalidArchive
            }

            // Sanitize + path-prefix check before writing.
            guard let safeRelative = sanitize(entryName: filename) else {
                NSLog("[NSFW/Zip] Skipping unsafe entry: %@", filename)
                try skip(handle, count: compressedSize)
                continue
            }
            let filePath = destinationDir.appendingPathComponent(safeRelative)
            let resolved = filePath.standardizedFileURL.resolvingSymlinksInPath().path
            guard resolved == destRoot || resolved.hasPrefix(destRootPrefix) else {
                NSLog("[NSFW/Zip] Skipping entry escaping destination: %@", filename)
                try skip(handle, count: compressedSize)
                continue
            }

            if safeRelative.hasSuffix("/") {
                try fm.createDirectory(at: filePath, withIntermediateDirectories: true)
                // Directory entries should carry zero payload, but skip
                // defensively in case a producer wrote some.
                if compressedSize > 0 { try skip(handle, count: compressedSize) }
                continue
            }

            try fm.createDirectory(at: filePath.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            fm.createFile(atPath: filePath.path, contents: nil)
            let outHandle = try FileHandle(forWritingTo: filePath)
            defer { try? outHandle.close() }

            switch compressionMethod {
            case 0:  // stored (no compression)
                try streamCopy(from: handle, to: outHandle, count: compressedSize)
            case 8:  // deflate
                try streamInflate(from: handle, to: outHandle, count: compressedSize)
            default:
                NSLog("[NSFW/Zip] Unsupported compression method %d for %@",
                      compressionMethod, filename)
                try skip(handle, count: compressedSize)
            }
        }
    }

    /// Extract ZIP data already in memory. Used for tests and any caller
    /// that already has the bytes — large on-disk archives go through
    /// `extract(_:to:)` to avoid loading the whole file.
    static func extract(data: Data, to destinationDir: URL) throws {
        // Tee the bytes to a tempfile so we can use the streaming path
        // uniformly. The extra copy is acceptable for small in-memory data.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zipx_\(UUID().uuidString).zip")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try extract(tmp, to: destinationDir)
    }

    /// Returns a relative, traversal-free path, or nil if the entry name is
    /// unsafe (absolute path, "..", drive letter, etc.).
    private static func sanitize(entryName: String) -> String? {
        guard !entryName.isEmpty else { return nil }
        if entryName.hasPrefix("/") || entryName.hasPrefix("\\") { return nil }
        if entryName.count >= 2 {
            let second = entryName[entryName.index(entryName.startIndex, offsetBy: 1)]
            if second == ":" { return nil }
        }
        let normalised = entryName.replacingOccurrences(of: "\\", with: "/")
        let trailingSlash = normalised.hasSuffix("/")
        let parts = normalised.split(separator: "/", omittingEmptySubsequences: true)
        for part in parts {
            if part == ".." || part == "." { return nil }
        }
        let rebuilt = parts.joined(separator: "/")
        guard !rebuilt.isEmpty else { return nil }
        return trailingSlash ? rebuilt + "/" : rebuilt
    }

    // MARK: - FileHandle helpers

    /// Read exactly `count` bytes from the handle, or return nil on EOF.
    private static func readExact(_ handle: FileHandle, count: Int) throws -> Data? {
        guard count > 0 else { return Data() }
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            guard let chunk = try handle.read(upToCount: count - buffer.count),
                  !chunk.isEmpty else {
                return buffer.isEmpty ? nil : nil
            }
            buffer.append(chunk)
        }
        return buffer
    }

    private static func skip(_ handle: FileHandle, count: Int) throws {
        guard count > 0 else { return }
        let pos = try handle.offset()
        try handle.seek(toOffset: pos + UInt64(count))
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    // MARK: - Streaming I/O

    private static let chunkSize = 1 << 15  // 32 KB

    /// Copy `count` bytes from `inHandle` to `outHandle` in 32 KB chunks
    /// (stored-method entries).
    private static func streamCopy(from inHandle: FileHandle,
                                   to outHandle: FileHandle,
                                   count: Int) throws {
        var remaining = count
        while remaining > 0 {
            let toRead = min(remaining, chunkSize)
            guard let chunk = try inHandle.read(upToCount: toRead),
                  !chunk.isEmpty else {
                throw ZipError.invalidArchive
            }
            try outHandle.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    /// Stream-decompress `count` compressed bytes from `inHandle` and write
    /// the decompressed bytes to `outHandle`. Peak memory is `2 * chunkSize`
    /// regardless of entry size — fixes C5 (model installs OOM'ing on
    /// 150 MB .zip via `Data(contentsOf:)`).
    private static func streamInflate(from inHandle: FileHandle,
                                      to outHandle: FileHandle,
                                      count: Int) throws {
        let srcBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { srcBuf.deallocate() }
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstBuf.deallocate() }

        let streamPtr = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPtr.deallocate() }
        streamPtr.initialize(to: compression_stream(
            dst_ptr: dstBuf,
            dst_size: chunkSize,
            src_ptr: srcBuf,
            src_size: 0,
            state: nil
        ))

        guard compression_stream_init(streamPtr, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.decompressionFailed
        }
        defer { compression_stream_destroy(streamPtr) }

        var remaining = count
        var inputExhausted = false

        loop: while true {
            // Refill source if drained and more compressed bytes remain.
            if streamPtr.pointee.src_size == 0 && remaining > 0 {
                let toRead = min(remaining, chunkSize)
                guard let chunk = try inHandle.read(upToCount: toRead),
                      !chunk.isEmpty else {
                    throw ZipError.invalidArchive
                }
                let n = chunk.count
                chunk.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                        srcBuf.update(from: base, count: n)
                    }
                }
                streamPtr.pointee.src_ptr  = UnsafePointer(srcBuf)
                streamPtr.pointee.src_size = n
                remaining -= n
                if remaining == 0 { inputExhausted = true }
            } else if streamPtr.pointee.src_size == 0 {
                inputExhausted = true
            }

            let flags: Int32 = inputExhausted ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(streamPtr, flags)

            // Drain produced output.
            let produced = chunkSize - streamPtr.pointee.dst_size
            if produced > 0 {
                let outChunk = Data(bytes: dstBuf, count: produced)
                try outHandle.write(contentsOf: outChunk)
                streamPtr.pointee.dst_ptr  = dstBuf
                streamPtr.pointee.dst_size = chunkSize
            }

            switch status {
            case COMPRESSION_STATUS_END:
                break loop
            case COMPRESSION_STATUS_OK:
                continue
            default:
                throw ZipError.decompressionFailed
            }
        }
    }
}

// MARK: - Errors

enum ZipError: Error, LocalizedError {
    case decompressionFailed
    case invalidArchive

    var errorDescription: String? {
        switch self {
        case .decompressionFailed: return "Failed to decompress ZIP entry"
        case .invalidArchive: return "Invalid ZIP archive"
        }
    }
}
