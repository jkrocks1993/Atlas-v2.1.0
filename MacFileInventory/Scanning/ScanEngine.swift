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
            let started = Date()
            var walked = 0
            var estimate = 12_000.0

            func tick(_ fraction: Double, _ detail: String) {
                let now = Date()
                guard now.timeIntervalSince(lastUI) > 0.20 || fraction >= 0.999 else { return }
                lastUI = now
                var eta: TimeInterval?
                if fraction > 0.02 && fraction < 0.99 {
                    let elapsed = now.timeIntervalSince(started)
                    eta = elapsed * (1.0 - fraction) / fraction
                }
                onTick(min(0.99, max(0.0, fraction)), eta, detail)
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
                        tick(0.62 * min(1.0, Double(walked) / estimate), walkedFile.url.path)
                        if Date().timeIntervalSince(lastUI) > 0.25 {
                            onFile(record)
                            onPath(walkedFile.url.path)
                        }
                    },
                    onPath: { path in
                        tick(0.62 * min(1.0, Double(max(walked, 1)) / max(estimate, 1)), path)
                    }
                )

                if self.control.isStopped {
                    stats.uncompared = files.values.filter { $0.comparisonStatus == .uncompared || $0.comparisonStatus == .pending }.count
                    liveStore.close()
                    let storeURL = try ResultStore.build(from: files, groups: [:])
                    files.removeAll(keepingCapacity: false)
                    onFinished(.success((storeURL, stats)))
                    return
                }

                onClassifying("Comparing file contents…")
                let total = max(files.count, 1)
                var done = 0
                let groups = DuplicateEngine.classify(
                    files: &files,
                    control: self.control,
                    onProgress: { text in
                        done += 1
                        let frac = 0.62 + 0.37 * min(1.0, Double(done) / Double(total))
                        tick(frac, text)
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
                // Build the final immutable snapshot only once. Until this point the user has
                // already been able to browse every completed category from the live database.
                liveStore.close()
                let storeURL = try ResultStore.build(from: files, groups: groups)
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
}
