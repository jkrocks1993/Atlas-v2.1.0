import Foundation

/// Cooperative pause / stop flag shared with walker and analyzers.
final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _paused = false
    private var _stopped = false

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
        lock.lock(); _stopped = false; _paused = false; lock.unlock()
    }

    func waitIfPaused() {
        while isPaused && !isStopped {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
