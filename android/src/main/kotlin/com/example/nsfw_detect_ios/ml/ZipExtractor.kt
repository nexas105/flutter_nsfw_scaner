package com.example.nsfw_detect_ios.ml

import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

/**
 * Minimal ZIP extractor with no third-party dependency. Pendant to
 * `ios/Classes/ml/ZipExtractor.swift`.
 *
 * Defends against path-traversal entries (`../foo`) by validating each entry's
 * canonical path stays inside [destDir], plus a configurable triad of
 * resource limits — total expanded size, entry count, per-entry expansion
 * ratio — that catch the standard zip-bomb shapes.
 */
object ZipExtractor {

    /**
     * Extract [zipFile] into [destDir] (created if missing).
     *
     * @param maxTotalBytes hard cap on the total uncompressed bytes written
     *   across all entries. Aborts mid-stream the moment it's hit.
     * @param maxEntries hard cap on the number of entries — stops before
     *   reading the next header.
     * @param maxCompressionRatio per-entry `expanded / compressed` ceiling.
     *   200:1 is well above anything well-compressed real data hits in
     *   practice; classic zip bombs run 1000:1 and up. Only enforced when
     *   the compressed entry has a non-trivial size (>= 64 bytes) so a
     *   tiny header-only entry doesn't trip a false positive.
     */
    fun extract(
        zipFile: File,
        destDir: File,
        maxTotalBytes: Long = Long.MAX_VALUE,
        maxEntries: Int = Int.MAX_VALUE,
        maxCompressionRatio: Double = Double.POSITIVE_INFINITY,
    ) {
        if (!destDir.exists()) destDir.mkdirs()
        val destCanonical = destDir.canonicalPath
        var entryCount = 0
        var totalProduced = 0L

        zipFile.inputStream().use { fis ->
            ZipInputStream(fis.buffered()).use { zis ->
                while (true) {
                    val entry = zis.nextEntry ?: break
                    try {
                        entryCount += 1
                        if (entryCount > maxEntries) {
                            throw ZipException("ZIP archive exceeded the $maxEntries-entry limit")
                        }

                        val name = entry.name
                        if (name.isEmpty()) continue

                        val outFile = File(destDir, name)
                        // Path-traversal guard: resolved file must remain inside destDir.
                        val outCanonical = outFile.canonicalPath
                        if (!outCanonical.startsWith(destCanonical + File.separator) &&
                            outCanonical != destCanonical) {
                            throw ZipException("Refusing path-traversal entry: $name")
                        }

                        if (entry.isDirectory) {
                            outFile.mkdirs()
                            continue
                        }

                        outFile.parentFile?.mkdirs()

                        // Per-entry budget: the smaller of (remaining total
                        // budget) and (compressed-size * ratio). The latter
                        // is the zip-bomb tripwire.
                        val compressedSize = entry.compressedSize
                        val perEntryCeiling = if (compressedSize >= 64 &&
                            maxCompressionRatio.isFinite()) {
                            val scaled = compressedSize.toDouble() * maxCompressionRatio
                            if (scaled > Long.MAX_VALUE.toDouble()) Long.MAX_VALUE
                            else scaled.toLong()
                        } else {
                            Long.MAX_VALUE
                        }
                        val remainingBudget = maxTotalBytes - totalProduced
                        val entryBudget = minOf(perEntryCeiling, remainingBudget)

                        var producedThisEntry = 0L
                        FileOutputStream(outFile).use { fos ->
                            val buf = ByteArray(32 * 1024)
                            while (true) {
                                val n = zis.read(buf)
                                if (n <= 0) break
                                producedThisEntry += n
                                if (producedThisEntry > entryBudget) {
                                    throw ZipException(
                                        "ZIP entry '${entry.name}' expanded past $entryBudget bytes — " +
                                            "compression-bomb signature (ratio cap=$maxCompressionRatio)"
                                    )
                                }
                                fos.write(buf, 0, n)
                            }
                        }
                        totalProduced += producedThisEntry
                        if (totalProduced > maxTotalBytes) {
                            throw ZipException(
                                "ZIP archive expanded to $totalProduced bytes — over the $maxTotalBytes cap"
                            )
                        }
                    } finally {
                        zis.closeEntry()
                    }
                }
            }
        }
    }
}

/** Errors raised by [ZipExtractor]. */
class ZipException(message: String) : RuntimeException(message)
