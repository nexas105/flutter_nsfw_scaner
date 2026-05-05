package com.example.nsfw_detect_ios.scanner

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.provider.MediaStore

/**
 * Queries ContentResolver for all images (and optionally videos) in the MediaStore.
 * Returns a list of AndroidMediaItem descriptors ready for scanning.
 */
data class AndroidMediaItem(
    val id: Long,
    val contentUri: Uri,
    val mediaType: String,   // "image" or "video"
    val displayName: String,
    val dateAdded: Long,     // seconds
    val dateModified: Long,  // seconds — used as scan-cache fingerprint
    val width: Int,
    val height: Int,
    val durationMs: Int?,    // null for images
)

object MediaStoreScanner {

    fun query(context: Context, config: ScanConfiguration): List<AndroidMediaItem> {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            MediaStore.MediaColumns.DURATION,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
        )

        val selection: String
        val selectionArgs: Array<String>

        if (config.includeVideos) {
            selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ? OR ${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
            selectionArgs = arrayOf(
                "${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}",
                "${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO}"
            )
        } else {
            selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
            selectionArgs = arrayOf("${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}")
        }

        val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC"
        val collectionUri = MediaStore.Files.getContentUri("external")

        val items = mutableListOf<AndroidMediaItem>()

        context.contentResolver.query(
            collectionUri,
            projection,
            selection,
            selectionArgs,
            sortOrder
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val dateCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val modifiedCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val widthCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
            val heightCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
            val durationCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DURATION)
            val mediaTypeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idCol)
                val mediaTypeInt = cursor.getInt(mediaTypeCol)
                val mediaType = when (mediaTypeInt) {
                    MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> "video"
                    else -> "image"
                }
                val durationRaw = cursor.getLong(durationCol)
                val durationMs = if (mediaType == "video" && durationRaw > 0) durationRaw.toInt() else null

                val contentUri = ContentUris.withAppendedId(collectionUri, id)

                items.add(
                    AndroidMediaItem(
                        id = id,
                        contentUri = contentUri,
                        mediaType = mediaType,
                        displayName = cursor.getString(nameCol) ?: "",
                        dateAdded = cursor.getLong(dateCol),
                        dateModified = cursor.getLong(modifiedCol),
                        width = cursor.getInt(widthCol),
                        height = cursor.getInt(heightCol),
                        durationMs = durationMs,
                    )
                )
            }
        }

        // Filter by assetIdentifiers if provided (numeric ID strings on Android)
        val identifiers = config.assetIdentifiers
        return if (identifiers != null) {
            val idSet = identifiers.toSet()
            items.filter { idSet.contains(it.id.toString()) }
        } else {
            items
        }
    }
}
