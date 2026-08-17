package com.example.nsfw_detect_ios.assets

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.util.UUID

/**
 * App-managed album store for Android.
 *
 * iOS albums are real `PHAssetCollection`s owned by the Photos app; Android's
 * MediaStore has no user-album concept (a media file lives in exactly one
 * `RELATIVE_PATH` bucket, and there is no add/remove/multi-membership API).
 * To keep parity with the iOS `NsfwDetector` album API — create, list,
 * add/remove, move, and multi-album membership — albums are kept in an
 * app-private SQLite database instead.
 *
 * Consequence of that choice (documented for callers): these albums are
 * visible only inside the host app. They are not written to MediaStore and do
 * not appear in the system gallery. Membership references assets by their
 * `localId` (the same string the scan pipeline emits); no media bytes are
 * copied or moved.
 *
 * Thread-safety: SQLiteOpenHelper provides its own internal synchronisation;
 * calls are safe from any thread.
 */
class AlbumStore private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DB_NAME, null, DB_VERSION) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS albums (" +
                "id TEXT PRIMARY KEY, title TEXT NOT NULL);"
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS album_assets (" +
                "album_id TEXT NOT NULL, local_id TEXT NOT NULL, " +
                "PRIMARY KEY (album_id, local_id));"
        )
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // Single schema version so far — nothing to migrate.
    }

    /** Create an album, returning its generated id. */
    fun createAlbum(title: String): String {
        val id = UUID.randomUUID().toString()
        writableDatabase.insert("albums", null, ContentValues().apply {
            put("id", id)
            put("title", title)
        })
        return id
    }

    /**
     * All user albums with their current membership count, shaped to match the
     * iOS `listAlbums` wire contract (`id`, `title`, `count`, `isUserAlbum`).
     */
    fun listAlbums(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        readableDatabase.rawQuery(
            "SELECT a.id, a.title, " +
                "(SELECT COUNT(*) FROM album_assets m WHERE m.album_id = a.id) AS cnt " +
                "FROM albums a ORDER BY a.title;",
            null
        ).use { c ->
            while (c.moveToNext()) {
                out.add(
                    mapOf(
                        "id" to c.getString(0),
                        "title" to c.getString(1),
                        "count" to c.getInt(2),
                        "isUserAlbum" to true,
                    )
                )
            }
        }
        return out
    }

    /** Add assets to an album (idempotent — REPLACE on the composite key). */
    fun addAssets(albumId: String, localIds: List<String>) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (localId in localIds) {
                db.insertWithOnConflict(
                    "album_assets", null,
                    ContentValues().apply {
                        put("album_id", albumId)
                        put("local_id", localId)
                    },
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** Remove assets from an album. No-op for rows that aren't members. */
    fun removeAssets(albumId: String, localIds: List<String>) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (localId in localIds) {
                db.delete(
                    "album_assets",
                    "album_id = ? AND local_id = ?",
                    arrayOf(albumId, localId),
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /**
     * Move assets into [toAlbumId]. When [fromAlbumId] is given the assets are
     * removed from that album first; otherwise they are removed from every
     * album. Matches the iOS `moveAssetsToAlbum` semantics (an asset leaves its
     * source membership rather than being duplicated). Atomic.
     */
    fun moveAssets(toAlbumId: String, localIds: List<String>, fromAlbumId: String?) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (localId in localIds) {
                if (fromAlbumId != null) {
                    db.delete(
                        "album_assets",
                        "album_id = ? AND local_id = ?",
                        arrayOf(fromAlbumId, localId),
                    )
                } else {
                    db.delete("album_assets", "local_id = ?", arrayOf(localId))
                }
                db.insertWithOnConflict(
                    "album_assets", null,
                    ContentValues().apply {
                        put("album_id", toAlbumId)
                        put("local_id", localId)
                    },
                    SQLiteDatabase.CONFLICT_REPLACE,
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /** Drop membership rows referencing deleted assets so counts stay honest. */
    fun forgetAssets(localIds: List<String>) {
        if (localIds.isEmpty()) return
        val db = writableDatabase
        db.beginTransaction()
        try {
            for (localId in localIds) {
                db.delete("album_assets", "local_id = ?", arrayOf(localId))
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    companion object {
        private const val DB_NAME = "nsfw_albums.db"
        private const val DB_VERSION = 1

        @Volatile
        private var instance: AlbumStore? = null

        fun getInstance(context: Context): AlbumStore =
            instance ?: synchronized(this) {
                instance ?: AlbumStore(context).also { instance = it }
            }
    }
}
