import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var location: ScanLocation = .entireMac
    @Published var enabledCategories: Set<FileCategory> = Set(FileCategory.allCases)
    @Published var phase: ScanPhase = .idle
    @Published var progress: Double = 0
    @Published var currentPath: String = ""
    @Published var statistics = ScanStatistics()
    // Retained during scanning only. After completion the full result set is moved to ResultStore.
    @Published var files: [UUID: FileRecord] = [:]
    @Published var groups: [UUID: DuplicateGroup] = [:]
    @Published var activeCategory: FileCategory = .images
    @Published private(set) var categoryProgress: [FileCategory: Double] = Dictionary(uniqueKeysWithValues: FileCategory.allCases.map { ($0, 0.0) })
    @Published private(set) var categoryCompleted: Set<FileCategory> = []
    @Published var activeSubtab: ResultSubtab = .unique
    @Published var activeKind: ContentKind? = nil
    @Published var searchText: String = ""
    @Published var sortField: SortField = .name
    @Published var sortDirection: SortDirection = .ascending
    @Published var resultLayout: ResultLayout = ResultLayout(rawValue: UserDefaults.standard.string(forKey: "atlas.resultLayout") ?? "") ?? .list
    @Published var selectedFileID: UUID?
    @Published var checkedIDs: Set<UUID> = []
    @Published var statusMessage: String = "Idle"
    @Published var alertTitle: String = ""
    @Published var alertMessage: String = ""
    @Published var showAlert: Bool = false
    @Published var showMoveConfirm: Bool = false
    @Published var showEnhance: Bool = false
    @Published var pendingMoveDestination: URL?
    @Published var pendingMoveRecords: [FileRecord] = []
    @Published var enhanceRequest = EnhancementRequest()
    @Published var isEnhancing: Bool = false
    @Published var etaLabel: String = ""
    // Cached result counts: UI never performs synchronous SQLite COUNTs while scanning.
    @Published private(set) var cachedCategoryCounts: [FileCategory: Int] = [:]
    @Published private(set) var cachedUniqueCounts: [FileCategory: Int] = [:]
    @Published private(set) var cachedDuplicateCounts: [FileCategory: Int] = [:]
    @Published private(set) var cachedUncomparedCounts: [FileCategory: Int] = [:]
    @Published var mountedVolumes: [URL] = DirectoryWalker.mountedVolumes()

    // The active tab is hydrated automatically from SQLite. Only lightweight display rows
    // stay in the list; full FileRecord values are fetched on selection/operation.
    @Published private(set) var visibleRows: [ListRow] = []
    @Published private(set) var isLoadingRows = false
    @Published private(set) var rowResetGeneration: Int = 0
    @Published private(set) var loadedFileRowCount: Int = 0
    @Published private(set) var displayRecords: [UUID: ListDisplayRecord] = [:]

    private var resultStore: ResultStore?
    private var engine: ScanEngine?
    private var receivedCount: Int = 0
    private var classifiedCount: Int = 0
    private var estimatedTotal: Double = 200
    private var sessionStartedProducing = false
    private var scanGeneration: Int = 0
    private var isClassifying = false
    private var rowGeneration: Int = 0
    private var rowOffset: Int = 0
    private var rowHasMore = false
    private var rowPageSize = 5000
    private var pendingRowWork: DispatchWorkItem?
    private var pendingSearchWork: DispatchWorkItem?
    private var searchGeneration: Int = 0

    init() {
        if let url = try? ResultStore.persistentURL(), FileManager.default.fileExists(atPath: url.path), let store = try? ResultStore(url: url) {
            resultStore = store
            // The database is the durable source of truth after a completed scan.
            // Restore the UI immediately; the active tab is hydrated off the main actor.
            phase = .completed
            statusMessage = "Completed — loading saved results…"
            categoryCompleted = Set(FileCategory.uiCases)
            categoryProgress = Dictionary(uniqueKeysWithValues: FileCategory.allCases.map { ($0, 1.0) })
            DispatchQueue.global(qos: .userInitiated).async { [weak self, store] in
                let stats = store.statistics()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statistics = stats
                    self.refreshCachedCountsAsync(store)
                    self.statusMessage = "Completed"
                    self.reloadRows()
                }
            }
        }
    }

    var selectedLocationText: String {
        if location.isEntireMac { return "Selected location: Entire Mac\n/" }
        return "Selected location:\n\(location.displayPath)"
    }

    var selectedFile: FileRecord? {
        guard let id = selectedFileID else { return nil }
        return files[id]
    }

    func record(for id: UUID) -> FileRecord? {
        if let cached = files[id] { return cached }
        guard let store = resultStore, let record = store.record(id) else { return nil }
        cacheRecord(record)
        return record
    }

    func cachedRecord(for id: UUID) -> FileRecord? { files[id] }
    func displayRecord(for id: UUID) -> ListDisplayRecord? { displayRecords[id] }

    private func cacheRecord(_ record: FileRecord) {
        files[record.id] = record
        if files.count > 900 {
            let keep = Set(visibleRows.compactMap(\.fileID)).union(selectedFileID.map { [$0] } ?? [])
            let keys = Array(files.keys)
            for key in keys where files.count > 450 && !keep.contains(key) { files.removeValue(forKey: key) }
        }
    }

    func isCategoryEnabled(_ category: FileCategory) -> Bool { enabledCategories.contains(category) }

    func toggleCategory(_ category: FileCategory) {
        if enabledCategories.contains(category) {
            if enabledCategories.count == 1 { return }
            enabledCategories.remove(category)
        } else {
            enabledCategories.insert(category)
        }
        if !enabledCategories.contains(activeCategory), let first = FileCategory.allCases.first(where: { enabledCategories.contains($0) }) {
            activeCategory = first
        }
        if phase == .completed { reloadRows() }
    }

    func chooseEntireMac() { location = .entireMac; refreshVolumes() }

    func chooseFolder() { if let url = NSOpenPanel.chooseFolder() { location = .folder(url) } }

    func chooseVolume(_ url: URL) { location = .folder(url) }

    func refreshVolumes() { mountedVolumes = DirectoryWalker.mountedVolumes() }

    func startScan() {
        guard phase != .scanning else { return }
        rowGeneration += 1
        pendingRowWork?.cancel()
        pendingSearchWork?.cancel()
        resultStore?.close()
        resultStore = nil
        visibleRows.removeAll(keepingCapacity: false)
        displayRecords.removeAll(keepingCapacity: false)
        rowOffset = 0
        rowHasMore = false
        files.removeAll(keepingCapacity: false)
        groups.removeAll(keepingCapacity: false)
        categoryProgress = Dictionary(uniqueKeysWithValues: FileCategory.allCases.map { ($0, 0.0) })
        categoryCompleted.removeAll()
        cachedCategoryCounts.removeAll(keepingCapacity: true)
        cachedUniqueCounts.removeAll(keepingCapacity: true)
        cachedDuplicateCounts.removeAll(keepingCapacity: true)
        cachedUncomparedCounts.removeAll(keepingCapacity: true)

        scanGeneration += 1
        let generation = scanGeneration
        sessionStartedProducing = false
        receivedCount = 0
        classifiedCount = 0
        estimatedTotal = 200
        isClassifying = false
        phase = .scanning
        progress = 0
        etaLabel = ""
        currentPath = location.displayPath
        statusMessage = "Scanning…"
        let engine = ScanEngine()
        self.engine = engine
        let enabled = enabledCategories
        let loc = location
        engine.run(
            location: loc,
            enabled: enabled,
            onPath: { [weak self] path in
                DispatchQueue.main.async {
                    guard let self, self.scanGeneration == generation else { return }
                    self.currentPath = path
                    self.updateWalkProgress()
                }
            },
            onFile: { [weak self] record in
                DispatchQueue.main.async {
                    guard let self, self.scanGeneration == generation else { return }
                    if !self.sessionStartedProducing {
                        self.files = [:]
                        self.groups = [:]
                        self.statistics = ScanStatistics()
                        self.checkedIDs = []
                        self.selectedFileID = nil
                        self.sessionStartedProducing = true
                    }
                    self.files[record.id] = record
                    self.statistics.add(record.category)
                    self.receivedCount += 1
                    self.estimatedTotal = max(self.estimatedTotal, Double(self.receivedCount) * 1.2)
                    self.updateWalkProgress()
                }
            },
            onClassifying: { [weak self] text in
                DispatchQueue.main.async {
                    guard let self, self.scanGeneration == generation else { return }
                    self.isClassifying = true
                    self.statusMessage = text
                }
            },
            onTick: { [weak self] fraction, eta, detail in
                DispatchQueue.main.async {
                    guard let self, self.scanGeneration == generation else { return }
                    self.progress = fraction
                    self.currentPath = detail
                    if let eta, eta.isFinite, eta > 1 { self.etaLabel = Self.formatETA(eta) }
                    else if fraction >= 1 { self.etaLabel = "" }
                }
            },
            onCategoryProgress: { [weak self] category, fraction in
                DispatchQueue.main.async {
                    guard let self, self.scanGeneration == generation else { return }
                    self.categoryProgress[category] = min(1, max(0, fraction))
                    self.statusMessage = "Comparing \(category.displayName)…"
                }
            },
            onCategoryFinished: { [weak self] category, url in
                DispatchQueue.main.async {
                    guard let self, self.scanGeneration == generation else { return }
                    self.categoryProgress[category] = 1
                    self.categoryCompleted.insert(category)
                    if self.resultStore == nil, let store = try? ResultStore(url: url) {
                        self.resultStore = store
                    }
                    self.statistics = self.resultStore?.statistics() ?? self.statistics
                    if let store = self.resultStore { self.refreshCachedCountsAsync(store) }
                    if self.activeCategory == category { self.reloadRows() }
                    self.statusMessage = "Ready: \(category.displayName)"
                }
            },
            onFinished: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, self.scanGeneration == generation else { return }
                    switch result {
                    case .success(let payload):
                        do {
                            self.resultStore?.close()
                            self.resultStore = try ResultStore(url: payload.storeURL)
                            self.files.removeAll(keepingCapacity: false)
                            if self.engine?.control.isStopped == true {
                                self.categoryCompleted = Set(FileCategory.uiCases.filter { self.resultStore?.count(category: $0) ?? 0 > 0 })
                            } else {
                                self.categoryCompleted = Set(FileCategory.uiCases.filter { (self.categoryProgress[$0] ?? 0) >= 1 })
                            }
                            self.groups.removeAll(keepingCapacity: false)
                            self.statistics = payload.stats
                            self.refreshCachedCountsAsync(self.resultStore)
                            self.progress = 1
                            if self.engine?.control.isStopped == true {
                                self.phase = .stopped
                                self.statusMessage = "Stopped"
                            } else {
                                self.phase = .completed
                                self.statusMessage = "Completed"
                            }
                            self.checkedIDs.removeAll(keepingCapacity: false)
                            self.selectedFileID = nil
                            self.reloadRows()
                        } catch {
                            self.phase = .stopped
                            self.statusMessage = "Stopped"
                            self.presentAlert("Results unavailable", error.localizedDescription)
                        }
                    case .failure(let error):
                        self.phase = .stopped
                        self.statusMessage = "Stopped"
                        self.presentAlert("Scan failed", error.localizedDescription)
                    }
                }
            }
        )
    }

    func pauseScan() { guard phase == .scanning else { return }; engine?.pause(); phase = .paused; statusMessage = "Paused" }
    func resumeScan() { guard phase == .paused else { return }; engine?.resume(); phase = .scanning; statusMessage = "Scanning…" }
    func stopScan() {
        guard phase == .scanning || phase == .paused else { return }
        engine?.stop()
        phase = .stopped
        statusMessage = "Stopping — releasing results…"
    }

    func count(for category: FileCategory) -> Int {
        // During an active scan use the cheap in-memory statistics counter.
        // Never walk `files` and never query SQLite from the SwiftUI render path.
        if phase == .scanning || phase == .paused { return statistics.count(for: category) }
        return cachedCategoryCounts[category] ?? statistics.count(for: category)
    }

    func uniqueCount(for category: FileCategory) -> Int {
        cachedUniqueCounts[category] ?? 0
    }

    func duplicateCount(for category: FileCategory) -> Int {
        cachedDuplicateCounts[category] ?? 0
    }

    func uncomparedCount(for category: FileCategory) -> Int {
        cachedUncomparedCounts[category] ?? 0
    }

    func kindCount(_ kind: ContentKind) -> Int {
        // Kind counts are only used after results exist; keep them off the UI thread.
        guard let store = resultStore, categoryCompleted.contains(activeCategory) else { return 0 }
        return store.count(category: activeCategory, status: activeSubtab.status, kind: kind)
    }

    private func matchesSubtab(_ rec: FileRecord) -> Bool { rec.comparisonStatus == activeSubtab.status }

    func clearChecks() { checkedIDs.removeAll() }

    func displayedRows() -> [ListRow] { visibleRows }

    var activeResultTotalCount: Int {
        switch activeSubtab {
        case .unique: return uniqueCount(for: activeCategory)
        case .duplicates: return duplicateCount(for: activeCategory)
        case .uncompared: return uncomparedCount(for: activeCategory)
        }
    }

    /// Debounced search: typing never triggers a database query per keystroke.
    func scheduleSearchReload() {
        pendingSearchWork?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.searchGeneration == generation else { return }
                self.reloadRows()
            }
        }
        pendingSearchWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    func reloadRows(preserveVisible: Bool = true) {
        guard resultStore != nil else { return }
        pendingRowWork?.cancel()
        rowGeneration += 1
        let generation = rowGeneration
        rowOffset = 0
        rowHasMore = false
        if !preserveVisible {
            visibleRows.removeAll(keepingCapacity: true)
            displayRecords.removeAll(keepingCapacity: true)
            loadedFileRowCount = 0
            selectedFileID = nil
        }
        isLoadingRows = true
        let store = resultStore!
        let category = activeCategory
        let subtab = activeSubtab
        let kind = activeKind
        let search = searchText
        let sort = sortField
        let direction = sortDirection
        let firstLimit = rowPageSize

        // Phase 1: one fast first-page read so the tab becomes usable immediately.
        let firstWork = DispatchWorkItem { [weak self, store] in
            guard self != nil else { return }
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.prepareSearchIndex()
            }
            let first = store.page(category: category, subtab: subtab, kind: kind, search: search, sort: sort, direction: direction, offset: 0, limit: firstLimit)
            DispatchQueue.main.async {
                guard let self, self.rowGeneration == generation else { return }
                self.mergePage(first, reset: true)
                self.rowHasMore = false // Full hydration below replaces paging entirely.
                // Phase 2: hydrate the complete active tab without any scroll-triggered work.
                self.hydrateFullRows(generation: generation, store: store, category: category, subtab: subtab, kind: kind, search: search, sort: sort, direction: direction)
            }
        }
        pendingRowWork = firstWork
        DispatchQueue.global(qos: .userInitiated).async(execute: firstWork)
    }

    private func hydrateFullRows(generation: Int, store: ResultStore, category: FileCategory, subtab: ResultSubtab, kind: ContentKind?, search: String, sort: SortField, direction: SortDirection) {
        DispatchQueue.global(qos: .utility).async { [weak self, store] in
            let full = store.allRows(category: category, subtab: subtab, kind: kind, search: search, sort: sort, direction: direction)
            let chunkSize = 20_000
            let rows = full.rows
            let recordsByID = Dictionary(uniqueKeysWithValues: full.records.map { ($0.id, $0) })
            let chunks: [ArraySlice<ListRow>] = stride(from: 0, to: rows.count, by: chunkSize).map { start in
                rows[start..<min(start + chunkSize, rows.count)]
            }
            if chunks.isEmpty {
                DispatchQueue.main.async {
                    guard let self, self.rowGeneration == generation else { return }
                    self.visibleRows = []
                    self.displayRecords = [:]
                    self.loadedFileRowCount = 0
                    self.rowHasMore = false
                    self.isLoadingRows = false
                    self.statusMessage = "Loaded 0 results"
                }
                return
            }
            for (index, chunk) in chunks.enumerated() {
                if index > 0 { Thread.sleep(forTimeInterval: 0.005) }
                var chunkRecords: [FileRecord] = []
                chunkRecords.reserveCapacity(chunk.compactMap(\.fileID).count)
                var seen = Set<UUID>()
                for row in chunk {
                    guard let id = row.fileID, !seen.contains(id), let record = recordsByID[id] else { continue }
                    seen.insert(id)
                    chunkRecords.append(record)
                }
                let page = ResultStore.Page(rows: Array(chunk), records: chunkRecords, hasMore: index < chunks.count - 1, nextOffset: min((index + 1) * chunkSize, rows.count))
                DispatchQueue.main.async {
                    guard let self, self.rowGeneration == generation else { return }
                    self.mergePage(page, reset: index == 0)
                    self.rowHasMore = false
                    if index == chunks.count - 1 {
                        self.isLoadingRows = false
                        self.statusMessage = "Loaded \(full.records.count.formatted()) results"
                    }
                }
            }
        }
    }

    var canLoadMoreRows: Bool { false }
    func requestMoreRows() {}
    func loadMoreRowsIfNeeded(_ row: ListRow, force: Bool = false) {}

    private func mergePage(_ page: ResultStore.Page, reset: Bool) {
        var map: [UUID: ListDisplayRecord] = [:]
        map.reserveCapacity(page.records.count)
        var attributes: [UUID: (isBest: Bool, indented: Bool)] = [:]
        for row in page.rows {
            switch row {
            case .best(_, let id): attributes[id] = (true, false)
            case .member(_, let id): attributes[id] = (false, true)
            case .unique(let id): attributes[id] = (false, false)
            case .separator: break
            }
        }
        for record in page.records {
            let a = attributes[record.id] ?? (false, false)
            map[record.id] = ListDisplayRecord(id: record.id, name: record.name, path: record.path, size: record.size, modified: record.modified, isBest: a.isBest, indented: a.indented)
        }
        if reset {
            visibleRows = page.rows
            displayRecords = map
            rowOffset = page.nextOffset
            rowResetGeneration += 1
        } else {
            visibleRows.append(contentsOf: page.rows)
            displayRecords.merge(map) { _, new in new }
            rowOffset = page.nextOffset
        }
        loadedFileRowCount = visibleRows.compactMap(\.fileID).count
        rowHasMore = false
        let visibleIDs = Set(visibleRows.compactMap(\.fileID))
        if reset, let selectedFileID, !visibleIDs.contains(selectedFileID) {
            self.selectedFileID = nil
        }
        if selectedFileID == nil, let first = visibleRows.compactMap(\.fileID).first { selectForPreview(first) }
    }

    func selectAllVisible() { checkedIDs.formUnion(visibleRows.compactMap(\.fileID)) }

    func selectInferiorDuplicates() {
        if let store = resultStore {
            checkedIDs.formUnion(store.duplicateIDs(category: activeCategory))
        } else {
            var extras: [UUID] = []
            for group in groups.values {
                for memberID in group.memberIDs {
                    guard let rec = files[memberID], rec.category == activeCategory, memberID != group.bestID else { continue }
                    extras.append(memberID)
                }
            }
            checkedIDs.formUnion(extras)
        }
        if activeSubtab != .duplicates { activeSubtab = .duplicates }
    }

    func setResultLayout(_ layout: ResultLayout) {
        resultLayout = layout
        UserDefaults.standard.set(layout.rawValue, forKey: "atlas.resultLayout")
    }

    func selectForPreview(_ id: UUID?) {
        guard let id else { selectedFileID = nil; return }
        _ = record(for: id)
        selectedFileID = id
    }

    func revealSelectedInFinder() { guard let rec = selectedFile else { return }; NSWorkspace.shared.activateFileViewerSelecting([rec.url]) }

    func toggleChecked(_ id: UUID) {
        if checkedIDs.contains(id) { checkedIDs.remove(id) } else { checkedIDs.insert(id) }
    }

    func moveSelection(direction: MoveCommandDirection, rows: [ListRow]) {
        let ids = rows.compactMap(\.fileID)
        guard !ids.isEmpty else { return }
        let current = selectedFileID.flatMap { ids.firstIndex(of: $0) } ?? 0
        var next = current
        switch direction { case .up: next = max(0, current - 1); case .down: next = min(ids.count - 1, current + 1); default: return }
        selectedFileID = ids[next]
    }

    func markSelectedAsNotDuplicate() {
        guard !checkedIDs.isEmpty, activeSubtab == .duplicates, let store = resultStore else { return }
        let ids = checkedIDs
        isLoadingRows = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            store.applyUserClassification(ids: ids, makeDuplicate: false)
            for _ in ids {
                OfflinePairModel.shared.learnUserCorrection(isDuplicate: false)
            }
            let stats = store.statistics()
            DispatchQueue.main.async {
                self.checkedIDs.subtract(ids)
                self.statistics = stats
                self.refreshCachedCountsAsync(store)
                self.statusMessage = "Marked \(ids.count) item(s) NOT DUPLICATE"
                self.reloadRows(preserveVisible: false)
            }
        }
    }

    func markSelectedAsNotUnique() {
        guard !checkedIDs.isEmpty, activeSubtab == .unique, let store = resultStore else { return }
        let ids = checkedIDs
        isLoadingRows = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            store.applyUserClassification(ids: ids, makeDuplicate: true)
            for _ in ids {
                OfflinePairModel.shared.learnUserCorrection(isDuplicate: true)
            }
            let stats = store.statistics()
            DispatchQueue.main.async {
                self.checkedIDs.subtract(ids)
                self.statistics = stats
                self.refreshCachedCountsAsync(store)
                self.statusMessage = "Marked \(ids.count) item(s) NOT UNIQUE"
                self.reloadRows(preserveVisible: false)
            }
        }
    }

    func deleteChecked() {
        let ids = checkedIDs
        guard !ids.isEmpty else { return }
        guard let store = resultStore else {
            let targets = ids.compactMap { files[$0] }
            do { try FileOperations.trash(urls: targets.map(\.url)); checkedIDs.subtract(ids); statusMessage = "Moved \(targets.count) item(s) to Trash" }
            catch { presentAlert("Delete failed", error.localizedDescription) }
            return
        }
        let targets = store.selectedRecords(ids: ids)
        guard !targets.isEmpty else { return }
        do {
            try FileOperations.trash(urls: targets.map(\.url))
            checkedIDs.subtract(ids)
            for id in ids { files.removeValue(forKey: id) }
            if let selectedFileID, ids.contains(selectedFileID) { self.selectedFileID = nil }
            statusMessage = "Moved \(targets.count) item(s) to Trash"
            isLoadingRows = true
            let storeForUpdate = store
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                storeForUpdate.remove(ids: ids)
                let stats = storeForUpdate.statistics()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statistics = stats
                    self.statusMessage = "Moved \(targets.count) item(s) to Trash"
                    self.reloadRows()
                }
            }
        } catch { presentAlert("Delete failed", error.localizedDescription) }
    }

    func requestMove() {
        let targets = checkedRecords()
        guard !targets.isEmpty else { return }
        guard let dest = NSOpenPanel.chooseDestination() else { return }
        pendingMoveDestination = dest
        pendingMoveRecords = targets
        showMoveConfirm = true
    }

    func confirmMove() {
        guard let dest = pendingMoveDestination else { return }
        let targets = pendingMoveRecords
        showMoveConfirm = false
        do {
            let moved = try FileOperations.move(urls: targets.map(\.url), to: dest)
            let ids = Set(targets.map(\.id))
            checkedIDs.subtract(ids)
            statusMessage = "Moved \(moved.count) item(s)"
            if let store = resultStore {
                isLoadingRows = true
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    store.updateAfterExternalMove(ids: ids)
                    let stats = store.statistics()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.statistics = stats
                        self.reloadRows()
                    }
                }
            } else {
                for id in ids { files.removeValue(forKey: id) }
            }
        } catch { presentAlert("Move failed", error.localizedDescription) }
        pendingMoveDestination = nil
        pendingMoveRecords = []
    }

    func cancelMove() { showMoveConfirm = false; pendingMoveDestination = nil; pendingMoveRecords = [] }

    func enhanceSelected() { guard selectedFile != nil else { return }; showEnhance = true }

    func runEnhancement() {
        guard let rec = selectedFile else { return }
        isEnhancing = true
        let request = enhanceRequest
        let url = rec.url
        let category = rec.category
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if category == .images { _ = try EnhanceEngine.enhanceImage(url: url, request: request, destinationDirectory: nil) }
                else if category == .videos { _ = try EnhanceEngine.enhanceVideo(url: url, request: request, destinationDirectory: nil) }
                else { throw EnhanceError.videoFailed("Enhancement is available for images and videos.") }
                DispatchQueue.main.async { self.isEnhancing = false; self.showEnhance = false; self.statusMessage = "Enhancement finished" }
            } catch { DispatchQueue.main.async { self.isEnhancing = false; self.presentAlert("Enhancement failed", error.localizedDescription) } }
        }
    }

    private func checkedRecords() -> [FileRecord] {
        if let store = resultStore { return store.selectedRecords(ids: checkedIDs) }
        return checkedIDs.compactMap { files[$0] }
    }

    private func refreshStatisticsAfterMutation(_ store: ResultStore) {
        statistics = store.statistics()
        refreshCachedCountsAsync(store)
    }

    private func refreshCachedCountsAsync(_ store: ResultStore?) {
        guard let store else { return }
        let categories = FileCategory.uiCases
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var totals: [FileCategory: Int] = [:]
            var unique: [FileCategory: Int] = [:]
            var duplicates: [FileCategory: Int] = [:]
            var uncompared: [FileCategory: Int] = [:]
            for category in categories {
                totals[category] = store.count(category: category)
                unique[category] = store.count(category: category, status: .unique)
                duplicates[category] = store.count(category: category, status: .duplicate)
                uncompared[category] = store.count(category: category, status: .uncompared)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cachedCategoryCounts = totals
                self.cachedUniqueCounts = unique
                self.cachedDuplicateCounts = duplicates
                self.cachedUncomparedCounts = uncompared
            }
        }
    }

    private static func formatETA(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "ETA \(s)s" }
        if s < 3600 { return "ETA \(s / 60)m \(s % 60)s" }
        return "ETA \(s / 3600)h \((s % 3600) / 60)m"
    }

    private func updateWalkProgress() {
        guard !isClassifying else { return }
        let denom = max(estimatedTotal, 1)
        progress = min(0.80, Double(receivedCount) / denom * 0.80)
    }

    func notifyResultsChanged() { if phase == .completed { reloadRows() } }

    func presentAlert(_ title: String, _ message: String) { alertTitle = title; alertMessage = message; showAlert = true }
}

private extension ResultSubtab {
    var status: ComparisonStatus {
        switch self { case .unique: return .unique; case .duplicates: return .duplicate; case .uncompared: return .uncompared }
    }
}
