package com.example.nsfw_detect_ios.ml

import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

/**
 * Minimal ZIP extractor with no third-party dependency. Pendant to
 * `ios/Classes/ml/ZipExtractor.swift`.
 *
 * Defends against path-traversal entries (`../foo`) by validating each entry's
 * canonical path stays inside [destDir].
 */
object ZipExtractor {

    /** Extract [zipFile] into [destDir] (created if missing). */
    fun extract(zipFile: File, destDir: File) {
        if (!destDir.exists()) destDir.mkdirs()
        val destCanonical = destDir.canonicalPath

        zipFile.inputStream().use { fis ->
            ZipInputStream(fis.buffered()).use { zis ->
                while (true) {
                    val entry = zis.nextEntry ?: break
                    try {
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
                        } else {
                            outFile.parentFile?.mkdirs()
                            FileOutputStream(outFile).use { fos ->
                                zis.copyTo(fos)
                            }
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
