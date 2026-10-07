import Foundation
import SQLite3

/// Local human-in-the-loop memory. Nothing is uploaded or synchronized.
final class FeedbackStore: @unchecked Sendable {
    static let shared = FeedbackStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "atlas.feedback", qos: .utility)
    private let url: URL

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Atlas", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("OfflineFeedback.sqlite")
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA busy_timeout=5000;")
        exec("CREATE TABLE IF NOT EXISTS pair_feedback (a TEXT NOT NULL, b TEXT NOT NULL, decision INTEGER NOT NULL, updated REAL NOT NULL, PRIMARY KEY(a,b));")
        exec("CREATE TABLE IF NOT EXISTS file_feedback (key TEXT PRIMARY KEY, decision INTEGER NOT NULL, updated REAL NOT NULL);")
        exec("CREATE INDEX IF NOT EXISTS idx_pair_decision ON pair_feedback(decision);")
    }

    deinit { sqlite3_close(db) }

    func stableKey(_ record: FileRecord) -> String {
        if let hash = record.contentFingerprint, !hash.isEmpty { return "sha256:" + hash }
        var value = record.path + "|" + String(record.size)
        if let modified = record.modified { value += "|" + String(modified.timeIntervalSinceReferenceDate) }
        return "path:" + value
    }

    func recordNotDuplicate(_ a: FileRecord, _ b: FileRecord) {
        let ka = stableKey(a), kb = stableKey(b)
        guard ka != kb else { return }
        let x = min(ka, kb), y = max(ka, kb)
        queue.sync {
            exec("INSERT OR REPLACE INTO pair_feedback(a,b,decision,updated) VALUES(?,?,0,?);", [x, y, String(Date().timeIntervalSinceReferenceDate)])
        }
    }

    func recordForceDuplicate(_ record: FileRecord) {
        let key = stableKey(record)
        queue.sync {
            exec("INSERT OR REPLACE INTO file_feedback(key,decision,updated) VALUES(?,?,?);", [key, "1", String(Date().timeIntervalSinceReferenceDate)])
        }
    }

    func isNotDuplicate(_ a: FileRecord, _ b: FileRecord) -> Bool {
        let ka = stableKey(a), kb = stableKey(b)
        guard ka != kb else { return false }
        let x = min(ka, kb), y = max(ka, kb)
        return queue.sync { scalar("SELECT decision FROM pair_feedback WHERE a=? AND b=? LIMIT 1;", [x, y]) == "0" }
    }

    func isForceDuplicate(_ record: FileRecord) -> Bool {
        queue.sync { scalar("SELECT decision FROM file_feedback WHERE key=? LIMIT 1;", [stableKey(record)]) == "1" }
    }

    private func exec(_ sql: String, _ binds: [String] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        _ = sqlite3_step(stmt)
    }

    private func scalar(_ sql: String, _ binds: [String]) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }
}
