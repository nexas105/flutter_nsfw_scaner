import Foundation
import SQLite3

/// Persistent cache of completed scan results, keyed by (localIdentifier, modelId).
/// Allows incremental scans to skip assets whose (modificationDate, modelId) match.
///
/// Storage: `Library/Application Support/nsfw_detect_ios/scans.db` — survives app
/// updates and is not auto-evicted by the system. Backed by libsqlite3 (system).
///
/// Thread-safety: every database call is serialised on a private queue. Reads are
/// synchronous; writes are asynchronous to keep them off the scan hot path.
final class ScanCache {

    static let shared = ScanCache()

    private var db: OpaquePointer?
    private var opened = false
    private let queue = DispatchQueue(label: "nsfw.scancache")

    // 50 trades minor crash-loss risk for ~50× fewer fsync()s on a 200k-asset scan.
    private static let batchSize = 50

    private struct PendingRecord {
        let localIdentifier: String
        let modelId: String
        let modificationDateMs: Int64
        let scannedAtMs: Int64
        let labelsJson: String
    }

    /// Pending writes — only ever read/written on `queue`.
    private var pending: [PendingRecord] = []

    private init() {}

    // MARK: - Lifecycle

    /// Opens the DB and runs migrations. Idempotent.
    @discardableResult
    func openIfNeeded() -> Bool {
        return queue.sync {
            guard !opened else { return true }
            do {
                let url = try Self.databaseURL()
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                var handle: OpaquePointer?
                let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK,
                      let handle = handle else {
                    NSLog("[NSFW] ScanCache: open failed at %@", url.path)
                    return false
                }
                self.db = handle
                sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
                sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
                guard migrateLocked() else {
                    sqlite3_close_v2(handle)
                    self.db = nil
                    return false
                }
                opened = true
                return true
            } catch {
                NSLog("[NSFW] ScanCache: openIfNeeded threw %@", "\(error)")
                return false
            }
        }
    }

    /// Schema migration framework backed by `PRAGMA user_version`.
    ///
    /// To add a new migration:
    ///   1. Bump `currentSchemaVersion` to N.
    ///   2. Add a `currentVersion < N` block in the order they should run.
    ///   3. Each block stays runnable on a partially-migrated DB
    ///      (`CREATE TABLE IF NOT EXISTS`, `ALTER TABLE ADD COLUMN`, etc).
    ///
    /// Downgrade: a DB that reports a higher `user_version` than this binary
    /// understands is dropped and recreated. Cache loss is preferred over
    /// running with an unknown schema.
    private static let currentSchemaVersion: Int32 = 1

    private func migrateLocked() -> Bool {
        guard let db = db else { return false }

        let storedVersion = readUserVersionLocked()

        // Downgrade — DB created by a newer plugin build. Wipe and start fresh.
        if storedVersion > Self.currentSchemaVersion {
            NSLog("[NSFW] ScanCache: DB version %d > supported %d — recreating",
                  storedVersion, Self.currentSchemaVersion)
            if sqlite3_exec(db, "DROP TABLE IF EXISTS scans;", nil, nil, nil) != SQLITE_OK {
                return false
            }
            return runMigrationsLocked(from: 0)
        }

        if storedVersion >= Self.currentSchemaVersion { return true }
        return runMigrationsLocked(from: storedVersion)
    }

    /// Runs every migration step from `startVersion` up to `currentSchemaVersion`,
    /// wrapped in a single transaction. Bumps `user_version` on success.
    private func runMigrationsLocked(from startVersion: Int32) -> Bool {
        guard let db = db else { return false }
        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            return false
        }

        var ok = true

        // Migration 0 -> 1: initial schema.
        if ok && startVersion < 1 {
            ok = sqlite3_exec(db, """
                CREATE TABLE IF NOT EXISTS scans (
                    local_identifier      TEXT NOT NULL,
                    model_id              TEXT NOT NULL,
                    modification_date_ms  INTEGER NOT NULL,
                    scanned_at_ms         INTEGER NOT NULL,
                    labels_json           TEXT NOT NULL,
                    PRIMARY KEY (local_identifier, model_id)
                );
                CREATE INDEX IF NOT EXISTS idx_scans_model ON scans(model_id);
            """, nil, nil, nil) == SQLITE_OK
        }

        // if ok && startVersion < 2 { ok = sqlite3_exec(db, "ALTER TABLE …", …) == SQLITE_OK }

        if ok {
            ok = sqlite3_exec(db,
                "PRAGMA user_version = \(Self.currentSchemaVersion);",
                nil, nil, nil) == SQLITE_OK
        }

        if ok {
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            return true
        }
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        return false
    }

    private func readUserVersionLocked() -> Int32 {
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0)
        }
        return 0
    }

    // MARK: - Reads

    /// Bulk-loads `[localIdentifier: modificationDateMs]` for the given model.
    /// Called once per scan to populate an in-memory filter map; lookups are then O(1).
    func loadFingerprints(modelId: String) -> [String: Int64] {
        return queue.sync {
            guard opened, let db = db else { return [:] }
            var stmt: OpaquePointer?
            let sql = "SELECT local_identifier, modification_date_ms FROM scans WHERE model_id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, modelId, -1, Self.SQLITE_TRANSIENT)
            var result: [String: Int64] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cstr = sqlite3_column_text(stmt, 0) else { continue }
                let id = String(cString: cstr)
                result[id] = sqlite3_column_int64(stmt, 1)
            }
            return result
        }
    }

    struct CachedRecord {
        let labelsJson: String
        let scannedAtMs: Int64
    }

    /// Returns the cached record if it matches (localId, modelId, modDate).
    /// A different modificationDateMs is treated as a miss — the asset must be re-scanned.
    func cachedRecord(localIdentifier: String, modelId: String, modificationDateMs: Int64) -> CachedRecord? {
        return queue.sync {
            guard opened, let db = db else { return nil }
            var stmt: OpaquePointer?
            let sql = """
                SELECT labels_json, scanned_at_ms FROM scans
                WHERE local_identifier = ? AND model_id = ? AND modification_date_ms = ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, localIdentifier, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, modelId, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, modificationDateMs)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let cstr = sqlite3_column_text(stmt, 0) {
                return CachedRecord(
                    labelsJson: String(cString: cstr),
                    scannedAtMs: sqlite3_column_int64(stmt, 1)
                )
            }
            return nil
        }
    }

    // MARK: - Writes

    /// Buffers a scan record. Writes are batched in groups of `batchSize` inside one
    /// transaction — collapses N fsync()s into 1, dramatic speedup over per-asset inserts.
    /// Asynchronous — keeps writes off the scan hot path.
    func record(
        localIdentifier: String,
        modelId: String,
        modificationDateMs: Int64,
        scannedAtMs: Int64,
        labelsJson: String
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.pending.append(PendingRecord(
                localIdentifier: localIdentifier,
                modelId: modelId,
                modificationDateMs: modificationDateMs,
                scannedAtMs: scannedAtMs,
                labelsJson: labelsJson
            ))
            if self.pending.count >= Self.batchSize {
                self.flushLocked()
            }
        }
    }

    /// Forces buffered records to disk in one transaction. Call at scan end and on cancel.
    /// A crash before flush() loses up to `batchSize`-1 records — those assets simply
    /// re-scan next time (cache miss, no incorrect data).
    func flush() {
        queue.sync { self.flushLocked() }
    }

    /// Must be called on `queue`.
    private func flushLocked() {
        guard opened, let db = db else { pending.removeAll(); return }
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)

        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            NSLog("[NSFW] ScanCache: flush BEGIN failed")
            return
        }

        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO scans
                (local_identifier, model_id, modification_date_ms, scanned_at_ms, labels_json)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(local_identifier, model_id) DO UPDATE SET
                modification_date_ms = excluded.modification_date_ms,
                scanned_at_ms        = excluded.scanned_at_ms,
                labels_json          = excluded.labels_json;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }

        for rec in batch {
            sqlite3_bind_text(stmt, 1, rec.localIdentifier, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, rec.modelId, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, rec.modificationDateMs)
            sqlite3_bind_int64(stmt, 4, rec.scannedAtMs)
            sqlite3_bind_text(stmt, 5, rec.labelsJson, -1, Self.SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Removes cached records. Pass `modelId` to clear a single model's entries,
    /// or omit to clear everything.
    func clear(modelId: String? = nil) {
        queue.sync {
            guard opened, let db = db else { return }
            if let modelId = modelId {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM scans WHERE model_id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, modelId, -1, Self.SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            } else {
                sqlite3_exec(db, "DELETE FROM scans;", nil, nil, nil)
            }
        }
    }

    // MARK: - Helpers

    /// SQLite expects this sentinel for "copy the bound text immediately".
    /// Swift can't reference SQLITE_TRANSIENT directly — it's a C macro defined as `(sqlite3_destructor_type)-1`.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func databaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("nsfw_detect_ios", isDirectory: true)
            .appendingPathComponent("scans.db", isDirectory: false)
    }
}
