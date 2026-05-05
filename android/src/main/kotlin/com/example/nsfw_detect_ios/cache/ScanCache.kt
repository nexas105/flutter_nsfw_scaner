package com.example.nsfw_detect_ios.cache

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.database.sqlite.SQLiteStatement
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Persistent cache of completed scan results, keyed by `(localIdentifier, modelId)`.
 * Mirrors `ios/Classes/cache/ScanCache.swift` — same schema, same semantics.
 *
 * Storage: app-private SQLite database (`scans.db`). Survives app updates and
 * uninstall-only-eviction.
 *
 * Thread-safety: SQLiteOpenHelper provides its own internal synchronisation.
 * Reads use `getReadableDatabase()`; writes use `getWritableDatabase()`. Calls
 * are safe from any thread.
 */
class ScanCache private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DB_NAME, null, DB_VERSION) {

    private data class PendingRecord(
        val localIdentifier: String,
        val modelId: String,
        val modificationDateMs: Long,
        val scannedAtMs: Long,
        val labelsJson: String,
        /** Optional JSON-encoded detection boxes — null for classifier rows / pre-v2. */
        val detectionsJson: String?,
    )

    private val pendingLock = Any()
    private val pending = mutableListOf<PendingRecord>()

    override fun onCreate(db: SQLiteDatabase) {
        // Fresh DB — run every migration from 0 to current.
        runMigrations(db, fromVersion = 0)
    }

    /**
     * Schema migration framework. SQLiteOpenHelper invokes this whenever
     * `DB_VERSION` increases; we replay every step between the stored version
     * and the current one.
     *
     * To add a new migration:
     *   1. Bump [DB_VERSION] to N.
     *   2. Add an `if (oldVersion < N)` block in [runMigrations].
     *   3. Each step stays idempotent (`CREATE TABLE IF NOT EXISTS`,
     *      `ALTER TABLE ... ADD COLUMN`, etc).
     */
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        runMigrations(db, fromVersion = oldVersion)
    }

    /**
     * Downgrade — DB created by a newer build than this one. Drop and recreate
     * rather than running with an unknown schema. Cache loss is preferred
     * over a partially-broken table.
     */
    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        Log.w(TAG, "DB downgrade $oldVersion -> $newVersion — recreating")
        db.execSQL("DROP TABLE IF EXISTS scans;")
        runMigrations(db, fromVersion = 0)
    }

    private fun runMigrations(db: SQLiteDatabase, fromVersion: Int) {
        db.beginTransaction()
        try {
            // 0 -> 1: initial schema
            if (fromVersion < 1) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS scans (
                        local_identifier      TEXT NOT NULL,
                        model_id              TEXT NOT NULL,
                        modification_date_ms  INTEGER NOT NULL,
                        scanned_at_ms         INTEGER NOT NULL,
                        labels_json           TEXT NOT NULL,
                        PRIMARY KEY (local_identifier, model_id)
                    );
                    """.trimIndent()
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS idx_scans_model ON scans(model_id);")
            }

            // 1 -> 2: add detections_json column for NudeNet detection results.
            // ALTER TABLE ADD COLUMN is non-destructive — old rows read NULL.
            if (fromVersion < 2) {
                db.execSQL("ALTER TABLE scans ADD COLUMN detections_json TEXT;")
            }

            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    /**
     * Bulk-loads `Map<localIdentifier, modificationDateMs>` for the given model.
     * Called once per scan to populate an in-memory filter map.
     */
    fun loadFingerprints(modelId: String): Map<String, Long> {
        flush()
        val out = HashMap<String, Long>()
        try {
            readableDatabase.rawQuery(
                "SELECT local_identifier, modification_date_ms FROM scans WHERE model_id = ?;",
                arrayOf(modelId)
            ).use { c ->
                while (c.moveToNext()) {
                    out[c.getString(0)] = c.getLong(1)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "loadFingerprints failed: ${e.message}")
        }
        return out
    }

    /**
     * Cached scan record. `detectionsJson` is null for classifier rows and
     * for pre-v2 entries (ALTER ADD COLUMN reads NULL on old rows).
     */
    data class CachedRecord(
        val labelsJson: String,
        val scannedAtMs: Long,
        val detectionsJson: String? = null,
    )

    /** Returns the cached record only when (localId, modelId, modDate) match. */
    fun cachedRecord(localIdentifier: String, modelId: String, modificationDateMs: Long): CachedRecord? {
        flush()
        return try {
            readableDatabase.rawQuery(
                """
                SELECT labels_json, scanned_at_ms, detections_json FROM scans
                WHERE local_identifier = ? AND model_id = ? AND modification_date_ms = ?;
                """.trimIndent(),
                arrayOf(localIdentifier, modelId, modificationDateMs.toString())
            ).use { c ->
                if (c.moveToFirst()) {
                    CachedRecord(
                        labelsJson = c.getString(0),
                        scannedAtMs = c.getLong(1),
                        detectionsJson = if (c.isNull(2)) null else c.getString(2),
                    )
                } else null
            }
        } catch (e: Exception) {
            Log.w(TAG, "cachedRecord failed: ${e.message}")
            null
        }
    }

    /**
     * Buffers a scan record. Writes are batched in groups of [BATCH_SIZE] inside one
     * transaction — collapses N disk syncs into 1, dramatic speedup over per-asset inserts.
     * Safe to call from any thread.
     */
    fun record(
        localIdentifier: String,
        modelId: String,
        modificationDateMs: Long,
        scannedAtMs: Long,
        labelsJson: String,
        detectionsJson: String? = null,
    ) {
        val shouldFlush: Boolean
        synchronized(pendingLock) {
            pending += PendingRecord(
                localIdentifier, modelId, modificationDateMs, scannedAtMs, labelsJson, detectionsJson
            )
            shouldFlush = pending.size >= BATCH_SIZE
        }
        if (shouldFlush) flush()
    }

    /**
     * Forces buffered records to disk in one transaction. Call at scan end and on cancel.
     * A crash before flush() loses up to [BATCH_SIZE]-1 records — those assets simply
     * re-scan next time (cache miss, no incorrect data).
     */
    fun flush() {
        val batch: List<PendingRecord>
        synchronized(pendingLock) {
            if (pending.isEmpty()) return
            batch = pending.toList()
            pending.clear()
        }
        try {
            val db = writableDatabase
            db.beginTransaction()
            try {
                val stmt: SQLiteStatement = db.compileStatement(
                    "INSERT OR REPLACE INTO scans " +
                        "(local_identifier, model_id, modification_date_ms, scanned_at_ms, labels_json, detections_json) " +
                        "VALUES (?, ?, ?, ?, ?, ?);"
                )
                stmt.use { s ->
                    for (rec in batch) {
                        s.clearBindings()
                        s.bindString(1, rec.localIdentifier)
                        s.bindString(2, rec.modelId)
                        s.bindLong(3, rec.modificationDateMs)
                        s.bindLong(4, rec.scannedAtMs)
                        s.bindString(5, rec.labelsJson)
                        if (rec.detectionsJson != null) {
                            s.bindString(6, rec.detectionsJson)
                        } else {
                            s.bindNull(6)
                        }
                        s.executeInsert()
                    }
                }
                db.setTransactionSuccessful()
            } finally {
                db.endTransaction()
            }
        } catch (e: Exception) {
            Log.w(TAG, "flush failed: ${e.message}")
        }
    }

    /** Clear all entries, or only those for [modelId]. */
    fun clear(modelId: String? = null) {
        synchronized(pendingLock) {
            if (modelId == null) {
                pending.clear()
            } else {
                pending.removeAll { it.modelId == modelId }
            }
        }
        try {
            if (modelId != null) {
                writableDatabase.delete("scans", "model_id = ?", arrayOf(modelId))
            } else {
                writableDatabase.delete("scans", null, null)
            }
        } catch (e: Exception) {
            Log.w(TAG, "clear failed: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "NSFW-ScanCache"
        private const val DB_NAME = "nsfw_scan_cache.db"
        private const val DB_VERSION = 2
        // 50 trades minor crash-loss risk for ~50× fewer disk syncs on a 200k-asset scan.
        private const val BATCH_SIZE = 50

        @Volatile private var instance: ScanCache? = null

        fun getInstance(context: Context): ScanCache =
            instance ?: synchronized(this) {
                instance ?: ScanCache(context.applicationContext).also { instance = it }
            }

        /** Encodes `[(category, confidence), ...]` to a compact JSON string. */
        fun encodeLabels(labels: List<Pair<String, Float>>): String {
            val arr = JSONArray()
            for ((cat, conf) in labels) {
                arr.put(JSONObject().apply {
                    put("category", cat)
                    put("confidence", conf.toDouble())
                })
            }
            return arr.toString()
        }

        /** Decodes the JSON produced by [encodeLabels]. Returns empty list on parse error. */
        fun decodeLabels(json: String): List<Pair<String, Float>> {
            return try {
                val arr = JSONArray(json)
                buildList {
                    for (i in 0 until arr.length()) {
                        val obj = arr.optJSONObject(i) ?: continue
                        val cat = obj.optString("category", null) ?: continue
                        val conf = obj.optDouble("confidence", Double.NaN)
                        if (conf.isNaN()) continue
                        add(cat to conf.toFloat())
                    }
                }
            } catch (e: Exception) {
                emptyList()
            }
        }

        /**
         * Encodes a list of detection maps (already in wire shape — i.e. as
         * produced by [com.example.nsfw_detect_ios.ml.BodyPartDetection.toMap])
         * to a compact JSON string. Returns null when the list is empty so the
         * column can stay NULL.
         */
        fun encodeDetections(detections: List<Map<String, Any?>>): String? {
            if (detections.isEmpty()) return null
            val arr = JSONArray()
            for (det in detections) {
                val obj = JSONObject()
                obj.put("label", det["label"])
                obj.put("confidence", det["confidence"])
                obj.put("aggregatedCategory", det["aggregatedCategory"])
                @Suppress("UNCHECKED_CAST")
                val box = det["box"] as? Map<String, Any?>
                if (box != null) {
                    obj.put("box", JSONObject().apply {
                        put("x", box["x"])
                        put("y", box["y"])
                        put("width", box["width"])
                        put("height", box["height"])
                    })
                }
                arr.put(obj)
            }
            return arr.toString()
        }

        /**
         * Decodes the JSON produced by [encodeDetections] back into wire-shape
         * maps suitable for embedding directly in the result event map.
         * Returns null on null input / parse error / empty array.
         */
        fun decodeDetections(json: String?): List<Map<String, Any>>? {
            if (json.isNullOrEmpty()) return null
            return try {
                val arr = JSONArray(json)
                if (arr.length() == 0) return null
                buildList {
                    for (i in 0 until arr.length()) {
                        val obj = arr.optJSONObject(i) ?: continue
                        val label = obj.optString("label", null) ?: continue
                        val conf  = obj.optDouble("confidence", Double.NaN)
                        if (conf.isNaN()) continue
                        val cat   = obj.optString("aggregatedCategory", "unknown")
                        val box   = obj.optJSONObject("box")
                        val map = mutableMapOf<String, Any>(
                            "label" to label,
                            "confidence" to conf,
                            "aggregatedCategory" to cat,
                        )
                        if (box != null) {
                            map["box"] = mapOf(
                                "x" to box.optDouble("x", 0.0),
                                "y" to box.optDouble("y", 0.0),
                                "width" to box.optDouble("width", 0.0),
                                "height" to box.optDouble("height", 0.0),
                            )
                        }
                        add(map)
                    }
                }.takeIf { it.isNotEmpty() }
            } catch (e: Exception) {
                null
            }
        }
    }
}
