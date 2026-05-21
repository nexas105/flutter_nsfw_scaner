import Foundation
import Compression

/// Minimal ZIP archive extractor.
/// No external dependencies. Supports stored and deflated entries.
enum ZipExtractor {

    /// Extract a ZIP archive to a destination directory.
    static func extract(_ zipURL: URL, to destinationDir: URL) throws {
        let data = try Data(contentsOf: zipURL)
        try extract(data: data, to: destinationDir)
    }

    /// Extract ZIP data to a destination directory.
    static func extract(data: Data, to destinationDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // Resolve once; we'll reject any entry whose final path doesn't stay
        // under this canonical destination (zip-slip defence).
        let destRoot = destinationDir.standardizedFileURL.resolvingSymlinksInPath().path
        let destRootPrefix = destRoot.hasSuffix("/") ? destRoot : destRoot + "/"

        var offset = 0
        while offset + 30 <= data.count {
            // Check local file header signature: PK\x03\x04
            guard data[offset] == 0x50, data[offset + 1] == 0x4B,
                  data[offset + 2] == 0x03, data[offset + 3] == 0x04 else {
                break
            }

            let generalPurpose  = readUInt16(data, at: offset + 6)
            let compressionMethod = readUInt16(data, at: offset + 8)
            let compressedSize  = Int(readUInt32(data, at: offset + 18))
            let uncompressedSize = Int(readUInt32(data, at: offset + 22))
            let filenameLen     = Int(readUInt16(data, at: offset + 26))
            let extraLen        = Int(readUInt16(data, at: offset + 28))

            let filenameStart = offset + 30
            guard filenameStart + filenameLen <= data.count else { break }

            let filenameData = data.subdata(in: filenameStart..<(filenameStart + filenameLen))
            let filename = String(data: filenameData, encoding: .utf8) ?? ""

            let dataStart = filenameStart + filenameLen + extraLen

            // Handle data descriptor (bit 3)
            if generalPurpose & 0x08 != 0 && compressedSize == 0 {
                offset = dataStart
                while offset + 4 < data.count {
                    if data[offset] == 0x50 && data[offset + 1] == 0x4B { break }
                    offset += 1
                }
                continue
            }

            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else { break }

            // Reject absolute paths, empty names, ".." traversal, and any
            // entry whose resolved path escapes destinationDir. Substring
            // sanitization is insufficient — see zip-slip CVE-2018-1002201.
            guard let safeRelative = sanitize(entryName: filename) else {
                NSLog("[NSFW/Zip] Skipping unsafe entry: %@", filename)
                offset = dataEnd
                continue
            }

            let filePath = destinationDir.appendingPathComponent(safeRelative)
            let resolved = filePath.standardizedFileURL.resolvingSymlinksInPath().path
            // Allow the destination itself (directory entries) or anything
            // strictly under it.
            guard resolved == destRoot || resolved.hasPrefix(destRootPrefix) else {
                NSLog("[NSFW/Zip] Skipping entry escaping destination: %@", filename)
                offset = dataEnd
                continue
            }

            if safeRelative.hasSuffix("/") {
                try fm.createDirectory(at: filePath, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)

                let compressedData = data.subdata(in: dataStart..<dataEnd)

                switch compressionMethod {
                case 0:
                    try compressedData.write(to: filePath)
                case 8:
                    let decompressed = try decompressDeflate(compressedData, expectedSize: uncompressedSize)
                    try decompressed.write(to: filePath)
                default:
                    NSLog("[NSFW/Zip] Unsupported compression method %d for %@", compressionMethod, filename)
                }
            }

            offset = dataEnd
        }
    }

    /// Returns a relative, traversal-free path, or nil if the entry name is
    /// unsafe (absolute path, "..", control chars, drive letter, etc.).
    private static func sanitize(entryName: String) -> String? {
        guard !entryName.isEmpty else { return nil }
        // Reject absolute paths and Windows-style drive prefixes.
        if entryName.hasPrefix("/") || entryName.hasPrefix("\\") { return nil }
        if entryName.count >= 2 {
            let second = entryName[entryName.index(entryName.startIndex, offsetBy: 1)]
            if second == ":" { return nil }
        }
        // Normalise separators and reject any ".." segment.
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

    // MARK: - Read helpers (no unsafe pointers)

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: - Deflate decompression

    private static func decompressDeflate(_ input: Data, expectedSize: Int) throws -> Data {
        // Use Apple's built-in buffer compression API (iOS 9+).
        // Much simpler than streaming and avoids all compression_stream init issues.
        let srcBytes = Array(input)
        let dstCapacity = max(expectedSize, input.count * 4)
        var dstBytes = [UInt8](repeating: 0, count: dstCapacity)

        let decodedSize = compression_decode_buffer(
            &dstBytes, dstCapacity,
            srcBytes, srcBytes.count,
            nil,  // scratch buffer (nil = auto)
            COMPRESSION_ZLIB
        )

        guard decodedSize > 0 else {
            throw ZipError.decompressionFailed
        }

        return Data(dstBytes.prefix(decodedSize))
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
