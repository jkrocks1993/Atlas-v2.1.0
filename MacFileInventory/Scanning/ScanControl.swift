import Foundation

/// Cooperative pause / stop flag shared with walker and analyzers.
final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _paused = false
    private var _stopped = false
    private var _tombstones: Set<UUID> = []

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return _paused
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }

    func pause() {
        lock.lock(); _paused = true; lock.unlock()
    }

    func resume() {
        lock.lock(); _paused = false; lock.unlock()
    }

    func stop() {
        lock.lock(); _stopped = true; _paused = false; lock.unlock()
    }

    func reset() {
        lock.lock(); _stopped = false; _paused = false; _tombstones.removeAll(); lock.unlock()
    }

    /// Files the user trashed while a scan is still running. The engine drops them
    /// before the final database is written so they do not come back.
    func tombstone(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        lock.lock(); _tombstones.formUnion(ids); lock.unlock()
    }

    func drainTombstones() -> Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        let ids = _tombstones
        _tombstones.removeAll(keepingCapacity: false)
        return ids
    }

    func waitIfPaused() {
        while isPaused && !isStopped {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
