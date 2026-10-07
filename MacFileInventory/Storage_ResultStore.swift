import Foundation
import SQLite3

// SQLite3 exposes SQLITE_TRANSIENT as a C macro, which Swift does not import.
// This is the standard Swift representation of the transient destructor.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ResultStore: @unchecked Sendable {
    struct Page {
        let rows: [ListRow]
        let records: [FileRecord]
        let hasMore: Bool
        let nextOffset: Int
    }

    private var db: OpaquePointer?
    let url: URL
    private let queue = DispatchQueue(label: "atlas.resultstore", qos: .userInitiated)
    private var ftsAvailable = false
    private var ftsNeedsRebuild = false
    private let ftsLock = NSLock()

    init(url: URL) throws {
        self.url = url
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        try configure()
    }

    deinit { sqlite3_close(db) }

    enum StoreError: LocalizedError {
        case open(String)
        case sql(String)
        case invalidData
        var errorDescription: String? {
            switch self {
            case .open(let s): return "Could not open result database: \(s)"
            case .sql(let s): return s
            case .invalidData: return "Invalid result database data."
            }
        }
    }

    static func persistentURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Atlas", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Results.sqlite")
    }

    static func makeFreshPersistent() throws -> ResultStore {
        let destination = try persistentURL()
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        return try ResultStore(url: destination)
    }

    static func build(from files: [UUID: FileRecord], groups: [UUID: DuplicateGroup]) throws -> URL {
        let fm = FileManager.default
        let destination = try persistentURL()
        let temp = destination.deletingLastPathComponent().appendingPathComponent("Results-\(UUID().uuidString).sqlite")
        _ = fm.createFile(atPath: temp.path, contents: nil)
        let store = try ResultStore(url: temp)
        try store.replaceContents(files: files, groups: groups)
        guard store.isValid else {
            store.close()
            throw StoreError.sql("Result database integrity check failed.")
        }
        store.close()
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
        return destination
    }

    var isValid: Bool {
        scalarText("PRAGMA integrity_check;") == "ok"
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    private func configure() throws {
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA busy_timeout=5000;")
        try exec("PRAGMA temp_store=FILE;")
        try exec("PRAGMA cache_size=-32768;")
        try exec("CREATE TABLE IF NOT EXISTS files (id TEXT PRIMARY KEY, path TEXT NOT NULL, size INTEGER NOT NULL, created REAL, modified REAL, category TEXT NOT NULL, uti TEXT, fingerprint TEXT, perceptual TEXT, status TEXT NOT NULL, group_id TEXT, is_best INTEGER NOT NULL, decode_failed INTEGER NOT NULL, content_kind TEXT NOT NULL);")
        try exec("CREATE TABLE IF NOT EXISTS groups (id TEXT PRIMARY KEY, category TEXT NOT NULL, best_id TEXT NOT NULL);")
        try exec("CREATE TABLE IF NOT EXISTS group_members (group_id TEXT NOT NULL, file_id TEXT NOT NULL, ordinal INTEGER NOT NULL, PRIMARY KEY(group_id,file_id));")
        try exec("CREATE INDEX IF NOT EXISTS idx_files_cat_status ON files(category,status);")
        try exec("CREATE INDEX IF NOT EXISTS idx_files_cat_status_path ON files(category,status,path COLLATE NOCASE,id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_files_cat_status_size ON files(category,status,size,id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_files_cat_status_modified ON files(category,status,modified,id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_files_cat_status_created ON files(category,status,created,id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_files_cat_kind_status ON files(category,content_kind,status);")
        try exec("CREATE INDEX IF NOT EXISTS idx_files_group ON files(group_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_members_group_ord ON group_members(group_id,ordinal);")
        try exec("CREATE INDEX IF NOT EXISTS idx_members_file ON group_members(file_id);")

        // FTS5 indexes path components (including folder names) so queries like
        // "desktop" can search a million-row result database without LOWER(path) LIKE.
        // Existing databases are rebuilt only once when the FTS table is first added.
        try exec("CREATE TABLE IF NOT EXISTS atlas_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        let hadFTS = scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='files_fts';", []) > 0
        do {
            try exec("CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(path, content='files', content_rowid='rowid', tokenize='unicode61', prefix='2 3 4');")
            ftsAvailable = true
            try exec("CREATE TRIGGER IF NOT EXISTS files_fts_ai AFTER INSERT ON files BEGIN INSERT INTO files_fts(rowid,path) VALUES(new.rowid,new.path); END;")
            try exec("CREATE TRIGGER IF NOT EXISTS files_fts_ad AFTER DELETE ON files BEGIN INSERT INTO files_fts(files_fts,rowid,path) VALUES('delete',old.rowid,old.path); END;")
            try exec("CREATE TRIGGER IF NOT EXISTS files_fts_au AFTER UPDATE OF path ON files BEGIN INSERT INTO files_fts(files_fts,rowid,path) VALUES('delete',old.rowid,old.path); INSERT INTO files_fts(rowid,path) VALUES(new.rowid,new.path); END;")
            // The marker persists across launches. If the app closes before the first
            // search, the next launch will still know the legacy database needs indexing.
            ftsNeedsRebuild = !hadFTS || scalarText("SELECT value FROM atlas_meta WHERE key='fts_path_index_ready';") != "1"
        } catch {
            ftsAvailable = false
            ftsNeedsRebuild = false
        }
    }

    private func replaceContents(files: [UUID: FileRecord], groups: [UUID: DuplicateGroup]) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("DELETE FROM group_members;")
            try exec("DELETE FROM groups;")
            try exec("DELETE FROM files;")

            let fileSQL = "INSERT INTO files(id,path,size,created,modified,category,uti,fingerprint,perceptual,status,group_id,is_best,decode_failed,content_kind) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);"
            let groupSQL = "INSERT INTO groups(id,category,best_id) VALUES(?,?,?);"
            let memberSQL = "INSERT INTO group_members(group_id,file_id,ordinal) VALUES(?,?,?);"
            var fp: OpaquePointer?
            var gp: OpaquePointer?
            var mp: OpaquePointer?
            guard sqlite3_prepare_v2(db, fileSQL, -1, &fp, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, groupSQL, -1, &gp, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, memberSQL, -1, &mp, nil) == SQLITE_OK else {
                throw StoreError.sql(lastError())
            }
            defer { sqlite3_finalize(fp); sqlite3_finalize(gp); sqlite3_finalize(mp) }

            var written = 0
            for rec in files.values {
                reset(fp)
                bind(fp, 1, rec.id.uuidString)
                bind(fp, 2, rec.path)
                bind(fp, 3, rec.size)
                bind(fp, 4, rec.created?.timeIntervalSinceReferenceDate)
                bind(fp, 5, rec.modified?.timeIntervalSinceReferenceDate)
                bind(fp, 6, rec.category.rawValue)
                bind(fp, 7, rec.uti)
                bind(fp, 8, rec.contentFingerprint)
                bind(fp, 9, rec.perceptualSignature)
                bind(fp, 10, rec.comparisonStatus.rawValue)
                bind(fp, 11, rec.groupID?.uuidString)
                bind(fp, 12, rec.isBest ? 1 : 0)
                bind(fp, 13, rec.decodeFailed ? 1 : 0)
                bind(fp, 14, rec.contentKind.rawValue)
                guard sqlite3_step(fp) == SQLITE_DONE else { throw StoreError.sql(lastError()) }
                written += 1
                if written % 10000 == 0 { try exec("SAVEPOINT atlas_batch;"); try exec("RELEASE SAVEPOINT atlas_batch;") }
            }

            for group in groups.values {
                reset(gp)
                bind(gp, 1, group.id.uuidString)
                bind(gp, 2, group.category.rawValue)
                bind(gp, 3, group.bestID.uuidString)
                guard sqlite3_step(gp) == SQLITE_DONE else { throw StoreError.sql(lastError()) }
                for (index, id) in group.memberIDs.enumerated() {
                    reset(mp)
                    bind(mp, 1, group.id.uuidString)
                    bind(mp, 2, id.uuidString)
                    bind(mp, 3, Int64(index))
                    guard sqlite3_step(mp) == SQLITE_DONE else { throw StoreError.sql(lastError()) }
                }
            }
            try exec("COMMIT;")
            if ftsAvailable {
                try exec("INSERT OR REPLACE INTO atlas_meta(key,value) VALUES('fts_path_index_ready','1');")
                ftsNeedsRebuild = false
            }
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Replaces only one category in the live result database. This is used while a scan is
    /// still running so completed categories become queryable immediately. Group rows are
    /// refreshed for groups that currently contain at least one member from this category.
    func replaceCategorySnapshot(category: FileCategory, files: [UUID: FileRecord], groups: [UUID: DuplicateGroup]) {
        transaction {
            let categoryIDs = files.values.filter { $0.category == category }.map(\.id)

            // Remove this category's previous file rows and memberships.
            if !categoryIDs.isEmpty {
                var delMembers: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM group_members WHERE file_id=?;", -1, &delMembers, nil) == SQLITE_OK {
                    for id in categoryIDs {
                        reset(delMembers)
                        bind(delMembers, 1, id.uuidString)
                        _ = sqlite3_step(delMembers)
                    }
                }
                sqlite3_finalize(delMembers)
            }
            var delFiles: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM files WHERE category=?;", -1, &delFiles, nil) == SQLITE_OK {
                bind(delFiles, 1, category.rawValue)
                _ = sqlite3_step(delFiles)
            }
            sqlite3_finalize(delFiles)

            // Rebuild groups whose declared category is this category. This removes stale
            // group IDs produced by later merges without touching other categories' groups.
            var oldGroupIDs: [String] = []
            oldGroupIDs = stringIDs("SELECT id FROM groups WHERE category=?;", [category.rawValue])
            for gid in oldGroupIDs {
                execNoThrow("DELETE FROM group_members WHERE group_id='\(gid)';")
            }
            execNoThrow("DELETE FROM groups WHERE category='\(category.rawValue)';")

            let fileSQL = "INSERT OR REPLACE INTO files(id,path,size,created,modified,category,uti,fingerprint,perceptual,status,group_id,is_best,decode_failed,content_kind) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);"
            var fp: OpaquePointer?
            guard sqlite3_prepare_v2(db, fileSQL, -1, &fp, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(fp) }
            for rec in files.values where rec.category == category {
                reset(fp)
                bind(fp, 1, rec.id.uuidString)
                bind(fp, 2, rec.path)
                bind(fp, 3, rec.size)
                bind(fp, 4, rec.created?.timeIntervalSinceReferenceDate)
                bind(fp, 5, rec.modified?.timeIntervalSinceReferenceDate)
                bind(fp, 6, rec.category.rawValue)
                bind(fp, 7, rec.uti)
                bind(fp, 8, rec.contentFingerprint)
                bind(fp, 9, rec.perceptualSignature)
                bind(fp, 10, rec.comparisonStatus.rawValue)
                bind(fp, 11, rec.groupID?.uuidString)
                bind(fp, 12, rec.isBest ? 1 : 0)
                bind(fp, 13, rec.decodeFailed ? 1 : 0)
                bind(fp, 14, rec.contentKind.rawValue)
                _ = sqlite3_step(fp)
            }

            let relevant = groups.values.filter { group in
                group.memberIDs.contains { files[$0]?.category == category }
            }
            var gp: OpaquePointer?
            var mp: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO groups(id,category,best_id) VALUES(?,?,?);", -1, &gp, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO group_members(group_id,file_id,ordinal) VALUES(?,?,?);", -1, &mp, nil) == SQLITE_OK else {
                sqlite3_finalize(gp); sqlite3_finalize(mp); return
            }
            for group in relevant {
                reset(gp)
                bind(gp, 1, group.id.uuidString)
                bind(gp, 2, group.category.rawValue)
                bind(gp, 3, group.bestID.uuidString)
                _ = sqlite3_step(gp)
                for (ordinal, id) in group.memberIDs.enumerated() {
                    reset(mp)
                    bind(mp, 1, group.id.uuidString)
                    bind(mp, 2, id.uuidString)
                    bind(mp, 3, ordinal)
                    _ = sqlite3_step(mp)
                }
            }
            sqlite3_finalize(gp)
            sqlite3_finalize(mp)

            // A group can contain members from a category that has not been persisted yet.
            // Keep its group row now; later category snapshots will add those file rows.
        }
    }

    func record(_ id: UUID) -> FileRecord? {
        var stmt: OpaquePointer?
        let sql = "SELECT id,path,size,created,modified,category,uti,fingerprint,perceptual,status,group_id,is_best,decode_failed,content_kind FROM files WHERE id=? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return decodeRecord(stmt)
    }

    func count(category: FileCategory) -> Int { scalarInt("SELECT COUNT(*) FROM files WHERE category=?;", [category.rawValue]) }
    func count(category: FileCategory, status: ComparisonStatus) -> Int { scalarInt("SELECT COUNT(*) FROM files WHERE category=? AND status=?;", [category.rawValue, status.rawValue]) }
    func count(category: FileCategory, status: ComparisonStatus, kind: ContentKind) -> Int { scalarInt("SELECT COUNT(*) FROM files WHERE category=? AND status=? AND content_kind=?;", [category.rawValue, status.rawValue, kind.rawValue]) }

    func statistics() -> ScanStatistics {
        var stats = ScanStatistics()
        for category in FileCategory.allCases {
            let total = count(category: category)
            switch category {
            case .images: stats.images = total
            case .videos: stats.videos = total
            case .audio: stats.audio = total
            case .pdfs: stats.pdfs = total
            case .word: stats.word = total
            case .powerpoint: stats.powerpoint = total
            case .excel: stats.excel = total
            case .zip: stats.zip = total
            case .rar: stats.rar = total
            case .other: stats.other = total
            case .unknown: stats.unknown = total
            }
            stats.filesScanned += total
            stats.uncompared += count(category: category, status: .uncompared)
        }
        return stats
    }

    func selectedRecords(ids: Set<UUID>) -> [FileRecord] {
        guard !ids.isEmpty else { return [] }
        var out: [FileRecord] = []
        out.reserveCapacity(ids.count)
        for id in ids { if let r = record(id) { out.append(r) } }
        return out
    }

    func duplicateIDs(category: FileCategory) -> [UUID] {
        let sql = "SELECT gm.file_id FROM group_members gm JOIN files f ON f.id=gm.file_id WHERE f.category=? AND f.status='duplicate' AND gm.file_id != (SELECT best_id FROM groups g WHERE g.id=gm.group_id);"
        return stringIDs(sql, [category.rawValue]).compactMap(UUID.init(uuidString:))
    }

    func prepareSearchIndex() {
        ftsLock.lock()
        defer { ftsLock.unlock() }
        guard ftsAvailable, ftsNeedsRebuild else { return }
        do {
            try exec("INSERT INTO files_fts(files_fts) VALUES('rebuild');")
            try exec("INSERT OR REPLACE INTO atlas_meta(key,value) VALUES('fts_path_index_ready','1');")
            ftsNeedsRebuild = false
        } catch {
            // Fall back to path substring search if FTS cannot be rebuilt on this SQLite build.
            ftsAvailable = false
        }
    }

    /// Returns the complete active result set in one background-friendly read.
    /// The UI uses this for automatic full-list hydration so scrolling never triggers
    /// another SQLite read. Duplicate groups are assembled in memory instead of using
    /// one SQL query per group (the old N+1 path was the main source of tab lag).
    func allRows(category: FileCategory, subtab: ResultSubtab, kind: ContentKind?, search: String, sort: SortField, direction: SortDirection) -> Page {
        switch subtab {
        case .unique:
            return allSimpleRows(category: category, status: .unique, kind: kind, search: search, sort: sort, direction: direction)
        case .uncompared:
            return allSimpleRows(category: category, status: .uncompared, kind: kind, search: search, sort: sort, direction: direction)
        case .duplicates:
            return allDuplicateRows(category: category, kind: kind, search: search, sort: sort, direction: direction)
        }
    }

    private func allSimpleRows(category: FileCategory, status: ComparisonStatus, kind: ContentKind?, search: String, sort: SortField, direction: SortDirection) -> Page {
        var whereParts = ["category=?", "status=?"]
        var binds: [String] = [category.rawValue, status.rawValue]
        if let kind { whereParts.append("content_kind=?"); binds.append(kind.rawValue) }
        appendSearch(&whereParts, &binds, search)
        let sql = "SELECT id,path,size,created,modified,category,uti,fingerprint,perceptual,status,group_id,is_best,decode_failed,content_kind FROM files WHERE \(whereParts.joined(separator: " AND ")) ORDER BY \(orderSQL(sort, direction));"
        let records = queryRecords(sql, binds)
        return Page(rows: records.map { .unique(fileID: $0.id) }, records: records, hasMore: false, nextOffset: records.count)
    }

    private func allDuplicateRows(category: FileCategory, kind: ContentKind?, search: String, sort: SortField, direction: SortDirection) -> Page {
        var whereParts = ["f.category=?", "f.status='duplicate'", "f.group_id IS NOT NULL"]
        var binds: [String] = [category.rawValue]
        if let kind { whereParts.append("f.content_kind=?"); binds.append(kind.rawValue) }
        appendSearch(&whereParts, &binds, search)
        let sql = "SELECT f.id,f.path,f.size,f.created,f.modified,f.category,f.uti,f.fingerprint,f.perceptual,f.status,f.group_id,f.is_best,f.decode_failed,f.content_kind FROM files f WHERE \(whereParts.joined(separator: " AND ")) ORDER BY f.group_id ASC, \(orderSQL(sort, direction, alias: "f"));"
        let records = queryRecords(sql, binds)

        var buckets: [UUID: [FileRecord]] = [:]
        buckets.reserveCapacity(records.count / 2)
        for record in records {
            if let gid = record.groupID { buckets[gid, default: []].append(record) }
        }

        struct BuiltGroup {
            let id: UUID
            let best: FileRecord
            let members: [FileRecord]
        }
        var built: [BuiltGroup] = []
        built.reserveCapacity(buckets.count)
        for (gid, members) in buckets {
            guard !members.isEmpty else { continue }
            let candidate = members.first(where: { $0.isBest }) ?? members.max(by: { lhs, rhs in
                if lhs.size != rhs.size { return lhs.size < rhs.size }
                if lhs.path != rhs.path { return lhs.path > rhs.path }
                return lhs.id.uuidString > rhs.id.uuidString
            })!
            let sortedOthers = members.filter { $0.id != candidate.id }.sorted { lhs, rhs in
                compareRecords(lhs, rhs, sort: sort, direction: direction)
            }
            built.append(BuiltGroup(id: gid, best: candidate, members: sortedOthers))
        }

        built.sort { lhs, rhs in
            if compareRecords(lhs.best, rhs.best, sort: sort, direction: direction) { return true }
            if compareRecords(rhs.best, lhs.best, sort: sort, direction: direction) { return false }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var rows: [ListRow] = []
        rows.reserveCapacity(records.count + max(0, built.count - 1))
        var displayRecords: [FileRecord] = []
        displayRecords.reserveCapacity(records.count)
        for (index, group) in built.enumerated() {
            rows.append(.best(groupID: group.id, fileID: group.best.id))
            displayRecords.append(group.best)
            for member in group.members {
                rows.append(.member(groupID: group.id, fileID: member.id))
                displayRecords.append(member)
            }
            if index < built.count - 1 { rows.append(.separator(groupID: group.id)) }
        }
        return Page(rows: rows, records: displayRecords, hasMore: false, nextOffset: rows.count)
    }

    private func compareRecords(_ lhs: FileRecord, _ rhs: FileRecord, sort: SortField, direction: SortDirection) -> Bool {
        let result: ComparisonResult
        switch sort {
        case .name:
            result = lhs.path.localizedCaseInsensitiveCompare(rhs.path)
        case .size:
            result = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .dateModified:
            let a = lhs.modified?.timeIntervalSinceReferenceDate ?? -Double.greatestFiniteMagnitude
            let b = rhs.modified?.timeIntervalSinceReferenceDate ?? -Double.greatestFiniteMagnitude
            result = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case .dateCreated:
            let a = lhs.created?.timeIntervalSinceReferenceDate ?? -Double.greatestFiniteMagnitude
            let b = rhs.created?.timeIntervalSinceReferenceDate ?? -Double.greatestFiniteMagnitude
            result = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
        case .fileType:
            result = lhs.ext.localizedCaseInsensitiveCompare(rhs.ext)
        }
        let adjusted = direction == .ascending ? result : (result == .orderedAscending ? .orderedDescending : (result == .orderedDescending ? .orderedAscending : .orderedSame))
        if adjusted != .orderedSame { return adjusted == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    func page(category: FileCategory, subtab: ResultSubtab, kind: ContentKind?, search: String, sort: SortField, direction: SortDirection, offset: Int, limit: Int) -> Page {
        switch subtab {
        case .unique, .uncompared:
            return simplePage(category: category, status: subtab == .unique ? .unique : .uncompared, kind: kind, search: search, sort: sort, direction: direction, offset: offset, limit: limit)
        case .duplicates:
            return duplicatePage(category: category, kind: kind, search: search, sort: sort, direction: direction, offset: offset, limit: limit)
        }
    }

    /// Applies an explicit user classification without touching the original files.
    /// NOT DUPLICATE records pairwise negative feedback against the previous group.
    /// NOT UNIQUE creates a singleton manual duplicate group so the user's assertion
    /// remains visible without inventing a relationship to another file.
    func applyUserClassification(ids: Set<UUID>, makeDuplicate: Bool) {
        guard !ids.isEmpty else { return }
        transaction {
            for id in ids {
                guard let rec = record(id) else { continue }

                if makeDuplicate {
                    // Detach from any automatic group first.
                    if let gid = rec.groupID {
                        let oldMembers = memberIDs(gid)
                        execBound("DELETE FROM group_members WHERE file_id=?;", binds: [id.uuidString])
                        repairGroup(gid)
                        for otherID in oldMembers where otherID != id {
                            _ = otherID
                        }
                    }
                    FeedbackStore.shared.recordForceDuplicate(rec)
                    let gid = UUID()
                    execBound("INSERT OR REPLACE INTO groups(id,category,best_id) VALUES(?,?,?);",
                              binds: [gid.uuidString, rec.category.rawValue, id.uuidString])
                    execBound("INSERT OR REPLACE INTO group_members(group_id,file_id,ordinal) VALUES(?,?,0);",
                              binds: [gid.uuidString, id.uuidString])
                    execBound("UPDATE files SET status='duplicate',group_id=?,is_best=1 WHERE id=?;",
                              binds: [gid.uuidString, id.uuidString])
                } else {
                    if let gid = rec.groupID {
                        let members = memberIDs(gid)
                        let otherRecords = members.filter { $0 != id }.compactMap { record($0) }
                        for other in otherRecords {
                            FeedbackStore.shared.recordNotDuplicate(rec, other)
                            if rec.category == .images && other.category == .images,
                               let a = ImageAnalyzer.signature(url: rec.url),
                               let b = ImageAnalyzer.signature(url: other.url) {
                                let ph = Hamming.distance(a.pHash, b.pHash)
                                let dh = Hamming.distance(a.dHash, b.dHash)
                                var acc = 0
                                if a.grid.count == b.grid.count {
                                    for i in a.grid.indices { acc += abs(Int(a.grid[i]) - Int(b.grid[i])) }
                                }
                                let mad = a.grid.isEmpty ? 255 : Double(acc) / Double(a.grid.count)
                                OfflinePairModel.shared.learn(phashDistance: ph, dhashDistance: dh, mad: mad, visionScore: nil, label: false)
                            }
                        }
                        execBound("DELETE FROM group_members WHERE file_id=?;", binds: [id.uuidString])
                        repairGroup(gid)
                    }
                    execBound("UPDATE files SET status='unique',group_id=NULL,is_best=0 WHERE id=?;", binds: [id.uuidString])
                }
            }
        }
    }

    private func repairGroup(_ gid: UUID) {
        let members = memberIDs(gid)
        if members.count >= 2 {
            let best = chooseBest(members)
            execBound("UPDATE groups SET best_id=? WHERE id=?;", binds: [best.uuidString, gid.uuidString])
            for id in members {
                execBound("UPDATE files SET status='duplicate',group_id=?,is_best=? WHERE id=?;",
                          binds: [gid.uuidString, id == best ? "1" : "0", id.uuidString])
            }
        } else if let only = members.first {
            execBound("DELETE FROM group_members WHERE group_id=?;", binds: [gid.uuidString])
            execBound("DELETE FROM groups WHERE id=?;", binds: [gid.uuidString])
            execBound("UPDATE files SET status='unique',group_id=NULL,is_best=0 WHERE id=?;", binds: [only.uuidString])
        } else {
            execBound("DELETE FROM groups WHERE id=?;", binds: [gid.uuidString])
        }
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        transaction {
            // Capture affected groups before removing their member rows.
            let affected = groupsContaining(ids)

            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM group_members WHERE file_id=?;", -1, &stmt, nil)
            for id in ids { reset(stmt); bind(stmt, 1, id.uuidString); _ = sqlite3_step(stmt) }
            sqlite3_finalize(stmt)

            // Promote BEST only in affected groups. No scan across all groups/files.
            for gid in affected {
                let members = memberIDs(gid)
                if members.count >= 2 {
                    let best = chooseBest(members)
                    execNoThrow("UPDATE groups SET best_id='\(best.uuidString)' WHERE id='\(gid.uuidString)';")
                    execNoThrow("UPDATE files SET is_best=0 WHERE group_id='\(gid.uuidString)';")
                    execNoThrow("UPDATE files SET is_best=1 WHERE id='\(best.uuidString)';")
                } else if members.count == 1 {
                    let only = members[0]
                    execNoThrow("UPDATE files SET status='unique',group_id=NULL,is_best=0 WHERE id='\(only.uuidString)';")
                    execNoThrow("DELETE FROM groups WHERE id='\(gid.uuidString)';")
                    execNoThrow("DELETE FROM group_members WHERE group_id='\(gid.uuidString)';")
                } else {
                    execNoThrow("DELETE FROM groups WHERE id='\(gid.uuidString)';")
                }
            }
            var del: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM files WHERE id=?;", -1, &del, nil)
            for id in ids { reset(del); bind(del, 1, id.uuidString); _ = sqlite3_step(del) }
            sqlite3_finalize(del)
        }
    }

    func updateAfterExternalMove(ids: Set<UUID>) { remove(ids: ids) }

    private func simplePage(category: FileCategory, status: ComparisonStatus, kind: ContentKind?, search: String, sort: SortField, direction: SortDirection, offset: Int, limit: Int) -> Page {
        var whereParts = ["category=?", "status=?"]
        var binds: [String] = [category.rawValue, status.rawValue]
        if let kind { whereParts.append("content_kind=?"); binds.append(kind.rawValue) }
        appendSearch(&whereParts, &binds, search)
        let sql = "SELECT id,path,size,created,modified,category,uti,fingerprint,perceptual,status,group_id,is_best,decode_failed,content_kind FROM files WHERE \(whereParts.joined(separator: " AND ")) ORDER BY \(orderSQL(sort, direction));"
        let records = queryRecords(sql, binds + [String(limit + 1), String(offset)])
        let hasMore = records.count > limit
        let pageRecords = Array(records.prefix(limit))
        return Page(rows: pageRecords.map { .unique(fileID: $0.id) }, records: pageRecords, hasMore: hasMore, nextOffset: offset + pageRecords.count)
    }

    private func duplicatePage(category: FileCategory, kind: ContentKind?, search: String, sort: SortField, direction: SortDirection, offset: Int, limit: Int) -> Page {
        var whereParts = ["f.category=?", "f.status='duplicate'"]
        var binds: [String] = [category.rawValue]
        if let kind { whereParts.append("f.content_kind=?"); binds.append(kind.rawValue) }
        appendSearch(&whereParts, &binds, search)

        let visibleBest = "COALESCE((SELECT g.best_id FROM groups g JOIN group_members gm2 ON gm2.group_id=g.id JOIN files f2 ON f2.id=gm2.file_id WHERE g.id=f.group_id AND f2.category=? AND f2.id=g.best_id LIMIT 1),(SELECT gm3.file_id FROM group_members gm3 JOIN files f3 ON f3.id=gm3.file_id WHERE gm3.group_id=f.group_id AND f3.category=? ORDER BY f3.size DESC, f3.created ASC, f3.path ASC LIMIT 1))"
        let sql = "SELECT DISTINCT f.group_id FROM files f WHERE \(whereParts.joined(separator: " AND ")) AND f.group_id IS NOT NULL ORDER BY (SELECT \(sortExpression(sort, alias: "bf")) FROM files bf WHERE bf.id=(\(visibleBest))) \(direction == .ascending ? "ASC" : "DESC"), f.group_id ASC LIMIT ? OFFSET ?;"
        let queryBinds = [category.rawValue, category.rawValue] + binds + [String(limit + 1), String(offset)]
        let groupIDs = queryGroupIDs(sql, queryBinds)
        let hasMore = groupIDs.count > limit
        let selected = Array(groupIDs.prefix(limit))
        let grouped = fetchDuplicateMembers(groupIDs: selected, category: category, kind: kind, search: search, sort: sort, direction: direction)

        var rows: [ListRow] = []
        var records: [FileRecord] = []
        rows.reserveCapacity(selected.count * 2)
        records.reserveCapacity(selected.count * 2)
        for (index, gid) in selected.enumerated() {
            guard let members = grouped[gid], !members.isEmpty else { continue }
            let bestID = members.first(where: { $0.isBest })?.id ?? members.max { a, b in
                if a.size != b.size { return a.size < b.size }
                if a.path != b.path { return a.path > b.path }
                return a.id.uuidString > b.id.uuidString
            }!.id
            let best = members.first(where: { $0.id == bestID })!
            rows.append(.best(groupID: gid, fileID: best.id))
            records.append(best)
            for rec in members.filter({ $0.id != best.id }) {
                rows.append(.member(groupID: gid, fileID: rec.id))
                records.append(rec)
            }
            if index < selected.count - 1 { rows.append(.separator(groupID: gid)) }
        }
        return Page(rows: rows, records: records, hasMore: hasMore, nextOffset: offset + selected.count)
    }

    private func fetchDuplicateMembers(groupIDs: [UUID], category: FileCategory, kind: ContentKind?, search: String, sort: SortField, direction: SortDirection) -> [UUID: [FileRecord]] {
        guard !groupIDs.isEmpty else { return [:] }
        var result: [UUID: [FileRecord]] = [:]
        let chunkSize = 400
        for start in stride(from: 0, to: groupIDs.count, by: chunkSize) {
            let end = min(start + chunkSize, groupIDs.count)
            let chunk = Array(groupIDs[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            var whereParts = ["gm.group_id IN (\(placeholders))", "f.category=?"]
            var binds = chunk.map(\.uuidString) + [category.rawValue]
            if let kind { whereParts.append("f.content_kind=?"); binds.append(kind.rawValue) }
            appendSearch(&whereParts, &binds, search)
            let sql = "SELECT f.id,f.path,f.size,f.created,f.modified,f.category,f.uti,f.fingerprint,f.perceptual,f.status,f.group_id,f.is_best,f.decode_failed,f.content_kind FROM group_members gm JOIN files f ON f.id=gm.file_id WHERE \(whereParts.joined(separator: " AND ")) ORDER BY gm.group_id ASC, \(orderSQL(sort, direction, alias: "f"));"
            let records = queryRecords(sql, binds)
            for record in records {
                if let gid = record.groupID { result[gid, default: []].append(record) }
            }
        }
        return result
    }

    private func sortExpression(_ sort: SortField, alias: String) -> String {
        switch sort {
        case .name: return "\(alias).path COLLATE NOCASE"
        case .size: return "\(alias).size"
        case .dateModified: return "COALESCE(\(alias).modified, -9.22e18)"
        case .dateCreated: return "COALESCE(\(alias).created, -9.22e18)"
        case .fileType: return "LOWER(substr(\(alias).path, instr(\(alias).path, '.') + 1))"
        }
    }

    private func groupMembers(_ gid: UUID, category: FileCategory, kind: ContentKind?, search: String, sort: SortField, direction: SortDirection) -> [FileRecord] {
        var whereParts = ["gm.group_id=?", "f.category=?"]
        var binds = [gid.uuidString, category.rawValue]
        if let kind { whereParts.append("f.content_kind=?"); binds.append(kind.rawValue) }
        appendSearch(&whereParts, &binds, search)
        let sql = "SELECT f.id,f.path,f.size,f.created,f.modified,f.category,f.uti,f.fingerprint,f.perceptual,f.status,f.group_id,f.is_best,f.decode_failed,f.content_kind FROM files f WHERE \(whereParts.joined(separator: " AND ")) ORDER BY f.group_id ASC, \(orderSQL(sort, direction, alias: "f"));"
        return queryRecords(sql, binds)
    }

    private func groupBest(_ gid: UUID) -> DuplicateGroup? {
        guard let row = queryOne("SELECT id,category,best_id FROM groups WHERE id=?", [gid.uuidString]) else { return nil }
        let id = UUID(uuidString: row[0]) ?? gid
        let cat = FileCategory(rawValue: row[1]) ?? .other
        let best = UUID(uuidString: row[2]) ?? gid
        return DuplicateGroup(id: id, category: cat, memberIDs: [], bestID: best)
    }

    private func groupsContaining(_ ids: Set<UUID>) -> Set<UUID> {
        var out = Set<UUID>()
        for id in ids {
            if let s = stringIDs("SELECT group_id FROM group_members WHERE file_id=?", [id.uuidString]).first, let gid = UUID(uuidString: s) { out.insert(gid) }
        }
        return out
    }

    private func memberIDs(_ gid: UUID) -> [UUID] { stringIDs("SELECT file_id FROM group_members WHERE group_id=? ORDER BY ordinal", [gid.uuidString]).compactMap(UUID.init(uuidString:)) }

    private func chooseBest(_ ids: [UUID]) -> UUID {
        var best: FileRecord?
        for id in ids {
            guard let r = record(id) else { continue }
            if let b = best {
                if r.size > b.size || (r.size == b.size && (r.created ?? .distantFuture) < (b.created ?? .distantFuture)) || (r.size == b.size && r.created == b.created && r.path < b.path) { best = r }
            } else { best = r }
        }
        return best?.id ?? ids[0]
    }

    private func appendSearch(_ parts: inout [String], _ binds: inout [String], _ search: String) {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let tokens = q.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
        if tokens.count == 1 {
            let token = tokens[0]
            let lower = token.lowercased()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let commonFolders: [String: String] = [
                "desktop": "Desktop", "documents": "Documents", "downloads": "Downloads",
                "pictures": "Pictures", "music": "Music", "movies": "Movies", "public": "Public"
            ]
            if let folder = commonFolders[lower] {
                // A bare common-folder search means that folder itself, not every
                // path merely containing the word. This makes `desktop` a real
                // Desktop scope while retaining indexed FTS for arbitrary searches.
                parts.append("path LIKE ?")
                binds.append(home + "/" + folder + "/%")
                return
            }
        }
        if ftsAvailable && !ftsNeedsRebuild {
            // FTS token-prefix search matches both the filename and any folder component.
            // Punctuation is treated as a separator, avoiding raw user text in MATCH syntax.
            if !tokens.isEmpty {
                let expression = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
                parts.append("path IN (SELECT path FROM files_fts WHERE files_fts MATCH ?)")
                binds.append(expression)
                return
            }
        }
        // Compatibility fallback for SQLite builds without FTS5, and punctuation-only queries.
        parts.append("LOWER(path) LIKE LOWER(?)")
        binds.append("%\(q)%")
    }

    private func orderSQL(_ sort: SortField, _ direction: SortDirection, alias: String = "files") -> String {
        "\(sortExpression(sort, alias: alias)) \(direction == .ascending ? "ASC" : "DESC"), \(alias).id ASC"
    }

    private func queryRecords(_ sql: String, _ binds: [String]) -> [FileRecord] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() { bind(stmt, Int32(i + 1), value) }
        var out: [FileRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let r = decodeRecord(stmt) { out.append(r) } }
        return out
    }

    private func queryGroupIDs(_ sql: String, _ binds: [String]) -> [UUID] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() { bind(stmt, Int32(i + 1), value) }
        var out: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let s = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: s)) { out.append(id) }
        }
        return out
    }

    private func queryOne(_ sql: String, _ binds: [String]) -> [String]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() { bind(stmt, Int32(i + 1), value) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var out: [String] = []
        for i in 0..<sqlite3_column_count(stmt) {
            if let s = sqlite3_column_text(stmt, i) { out.append(String(cString: s)) } else { out.append("") }
        }
        return out
    }

    private func stringIDs(_ sql: String, _ binds: [String]) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() { bind(stmt, Int32(i + 1), value) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { if let s = sqlite3_column_text(stmt, 0) { out.append(String(cString: s)) } }
        return out
    }

    private func scalarText(_ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: value)
    }

    private func scalarInt(_ sql: String, _ binds: [String]) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() { bind(stmt, Int32(i + 1), value) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func decodeRecord(_ stmt: OpaquePointer?) -> FileRecord? {
        guard let stmt,
              let idString = sqlite3_column_text(stmt, 0),
              let pathString = sqlite3_column_text(stmt, 1),
              let categoryString = sqlite3_column_text(stmt, 5),
              let statusString = sqlite3_column_text(stmt, 9),
              let kindString = sqlite3_column_text(stmt, 13),
              let id = UUID(uuidString: String(cString: idString)),
              let category = FileCategory(rawValue: String(cString: categoryString)),
              let status = ComparisonStatus(rawValue: String(cString: statusString)),
              let kind = ContentKind(rawValue: String(cString: kindString)) else { return nil }
        let path = String(cString: pathString)
        let created = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
        let modified = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
        let uti = text(stmt, 6)
        let fingerprint = text(stmt, 7)
        let perceptual = text(stmt, 8)
        let groupID = text(stmt, 10).flatMap(UUID.init(uuidString:))
        return FileRecord(id: id, url: URL(fileURLWithPath: path), category: category, size: sqlite3_column_int64(stmt, 2), created: created, modified: modified, uti: uti, contentFingerprint: fingerprint, perceptualSignature: perceptual, comparisonStatus: status, groupID: groupID, isBest: sqlite3_column_int(stmt, 11) != 0, decodeFailed: sqlite3_column_int(stmt, 12) != 0, contentKind: kind)
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let s = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: s)
    }

    private func reset(_ stmt: OpaquePointer?) { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) { if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, index) } }
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) { sqlite3_bind_int64(stmt, index, value) }
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) { sqlite3_bind_int(stmt, index, Int32(value)) }
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: TimeInterval?) { if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) } }

    private func execBound(_ sql: String, binds: [String]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        _ = sqlite3_step(stmt)
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError()
            sqlite3_free(error)
            throw StoreError.sql(message)
        }
    }
    private func execNoThrow(_ sql: String) { try? exec(sql) }
    private func transaction(_ body: () -> Void) { execNoThrow("BEGIN IMMEDIATE;"); body(); execNoThrow("COMMIT;") }
    private func lastError() -> String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error" }
}
