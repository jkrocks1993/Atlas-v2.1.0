import Foundation

final class ScanEngine: @unchecked Sendable {
    let control = ScanControl()
    private let walker = DirectoryWalker()

    func run(
        location: ScanLocation,
        enabled: Set<FileCategory>,
        onPath: @escaping (String) -> Void,
        onFile: @escaping (FileRecord) -> Void,
        onClassifying: @escaping (String) -> Void,
        onTick: @escaping (_ fraction: Double, _ eta: TimeInterval?, _ detail: String) -> Void,
        onCategoryProgress: @escaping (FileCategory, Double) -> Void = { _, _ in },
        onCategoryFinished: @escaping (FileCategory, URL) -> Void = { _, _ in },
        onPrepareFinalize: @escaping () -> Void = {},
        onFinished: @escaping (Result<(storeURL: URL, stats: ScanStatistics), Error>) -> Void
    ) {
        control.reset()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let liveStore: ResultStore
            do {
                liveStore = try ResultStore.makeFreshPersistent()
            } catch {
                onFinished(.failure(error))
                return
            }
            var files: [UUID: FileRecord] = [:]
            var stats = ScanStatistics()
            var lastUI = Date.distantPast
            var walked = 0
            var estimate = 12_000.0
            var compareStarted: Date?
            var compareSamples: [(Date, Int)] = []

            func publish(_ fraction: Double, _ eta: TimeInterval?, _ detail: String) {
                let now = Date()
                guard now.timeIntervalSince(lastUI) > 0.20 || fraction >= 0.999 else { return }
                lastUI = now
                onTick(min(0.99, max(0.0, fraction)), eta, detail)
            }

            func surveyFraction() -> Double {
                0.12 * min(1.0, Double(max(walked, 1)) / max(estimate, 1))
            }

            func comparisonETA(done: Int, total: Int) -> TimeInterval? {
                let now = Date()
                if compareStarted == nil { compareStarted = now }
                compareSamples.append((now, done))
                compareSamples.removeAll { now.timeIntervalSince($0.0) > 20 }
                guard let first = compareSamples.first else { return nil }
                let dt = now.timeIntervalSince(first.0)
                let delta = done - first.1
                guard dt >= 1.2, delta >= 3 else { return nil }
                let rate = Double(delta) / dt
                guard rate > 0.01 else { return nil }
                return Double(max(0, total - done)) / rate
            }

            do {
                try self.walker.walk(
                    location: location,
                    enabled: enabled,
                    control: self.control,
                    onFile: { walkedFile in
                        let category = TypeDetector.category(for: walkedFile.url)
                        guard enabled.contains(category) else { return }
                        let record = FileRecord(
                            url: walkedFile.url,
                            category: category,
                            size: walkedFile.size,
                            created: walkedFile.created,
                            modified: walkedFile.modified,
                            uti: walkedFile.uti ?? TypeDetector.utiString(for: walkedFile.url)
                        )
                        files[record.id] = record
                        stats.add(category)
                        walked += 1
                        if Double(walked) > estimate * 0.82 { estimate = Double(walked) / 0.82 }
                        publish(surveyFraction(), nil, walkedFile.url.path)
                        if Date().timeIntervalSince(lastUI) > 0.25 {
                            onFile(record)
                            onPath(walkedFile.url.path)
                        }
                    },
                    onPath: { path in
                        publish(surveyFraction(), nil, path)
                    }
                )

                if self.control.isStopped {
                    stats.uncompared = files.values.filter { $0.comparisonStatus == .uncompared || $0.comparisonStatus == .pending }.count
                    let dropped = self.control.drainTombstones()
                    var emptyGroups: [UUID: DuplicateGroup] = [:]
                    self.applyTombstones(files: &files, groups: &emptyGroups, dropped: dropped)
                    let storeURL = try self.finalize(liveStore: liveStore, files: files, groups: [:], prepare: onPrepareFinalize)
                    files.removeAll(keepingCapacity: false)
                    onFinished(.success((storeURL, stats)))
                    return
                }

                onClassifying("Comparing file contents…")
                let total = max(files.count, 1)
                var done = 0
                var groups = DuplicateEngine.classify(
                    files: &files,
                    control: self.control,
                    onProgress: { text in
                        done += 1
                        let frac = 0.12 + 0.86 * min(1.0, Double(done) / Double(total))
                        publish(frac, comparisonETA(done: done, total: total), text)
                        if Date().timeIntervalSince(lastUI) > 0.2 { onClassifying(text) }
                    },
                    onCategoryProgress: { category, fraction in
                        onCategoryProgress(category, fraction)
                    },
                    onCategoryFinished: { category, categoryFiles, categoryGroups in
                        liveStore.replaceCategorySnapshot(category: category, files: categoryFiles, groups: categoryGroups)
                        onCategoryFinished(category, liveStore.url)
                    }
                )
                stats.uncompared = files.values.filter { $0.comparisonStatus == .uncompared }.count

                // Persist the completed result set off the main actor. The UI receives only a
                // database URL and statistics, never the 500k-record dictionary/group graph.
                onClassifying("Finalizing results…")
                let dropped = self.control.drainTombstones()
                self.applyTombstones(files: &files, groups: &groups, dropped: dropped)
                let storeURL = try self.finalize(liveStore: liveStore, files: files, groups: groups, prepare: onPrepareFinalize)
                files.removeAll(keepingCapacity: false)
                var releasedGroups = groups
                releasedGroups.removeAll(keepingCapacity: false)
                onTick(1.0, 0, "Completed")
                onFinished(.success((storeURL, stats)))
            } catch {
                liveStore.close()
                files.removeAll(keepingCapacity: false)
                onFinished(.failure(error))
            }
        }
    }

    func pause() { control.pause() }
    func resume() { control.resume() }
    func stop() { control.stop() }
    func tombstone(_ ids: Set<UUID>) { control.tombstone(ids) }

    /// Closes the UI's connection before the live database file is replaced.
    /// Replacing Results.sqlite while that connection is still open makes the
    /// finished scan look empty.
    private func finalize(liveStore: ResultStore, files: [UUID: FileRecord], groups: [UUID: DuplicateGroup], prepare: @escaping () -> Void) throws -> URL {
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            prepare()
            gate.signal()
        }
        gate.wait()
        liveStore.close()
        return try ResultStore.build(from: files, groups: groups)
    }

    private func applyTombstones(files: inout [UUID: FileRecord], groups: inout [UUID: DuplicateGroup], dropped: Set<UUID>) {
        guard !dropped.isEmpty else { return }
        for id in dropped { files.removeValue(forKey: id) }
        var removeGroups: [UUID] = []
        for (gid, var group) in groups {
            group.memberIDs.removeAll { dropped.contains($0) || files[$0] == nil }
            if group.memberIDs.count < 2 {
                if let only = group.memberIDs.first, var rec = files[only] {
                    rec.comparisonStatus = .unique
                    rec.groupID = nil
                    rec.isBest = false
                    files[only] = rec
                }
                removeGroups.append(gid)
            } else {
                if !group.memberIDs.contains(group.bestID) {
                    group.bestID = group.memberIDs.max { (files[$0]?.size ?? 0) < (files[$1]?.size ?? 0) } ?? group.memberIDs[0]
                }
                if var best = files[group.bestID] {
                    best.isBest = true
                    best.comparisonStatus = .duplicate
                    best.groupID = gid
                    files[group.bestID] = best
                }
                for id in group.memberIDs where id != group.bestID {
                    if var rec = files[id] {
                        rec.isBest = false
                        rec.comparisonStatus = .duplicate
                        rec.groupID = gid
                        files[id] = rec
                    }
                }
                groups[gid] = group
            }
        }
        for gid in removeGroups { groups.removeValue(forKey: gid) }
    }
}
