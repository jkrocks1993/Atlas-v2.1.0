import Foundation

/// Small, fully local online classifier used only for ambiguous image pairs.
///
/// This is intentionally not a replacement for deterministic evidence. It learns from
/// trusted automatic matches and explicit user corrections, and is consulted only after
/// exact/perceptual gates have produced an ambiguous candidate.
final class OfflinePairModel {
    static let shared = OfflinePairModel()

    private struct State: Codable {
        var weights: [Double]
        var examples: Int
        var positives: Int
        var negatives: Int
    }

    private let lock = NSLock()
    private let url: URL
    private var state: State

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Atlas", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("OfflinePairModel.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(State.self, from: data),
           decoded.weights.count == 5 {
            state = decoded
        } else {
            // Conservative starting point. x values are similarity scores in 0...1.
            state = State(weights: [-7.0, 3.2, 2.8, 1.8, 4.0], examples: 0, positives: 0, negatives: 0)
        }
    }

    var trainedExamples: Int {
        lock.lock(); defer { lock.unlock() }
        return state.examples
    }

    /// User corrections are stored as strong local examples so the next scan
    /// is slightly more conservative (or slightly more willing) without overriding
    /// exact hashes.
    func learnUserCorrection(isDuplicate: Bool) {
        if isDuplicate {
            learn(phashDistance: 6, dhashDistance: 6, mad: 12, visionScore: 0.92, label: true)
        } else {
            learn(phashDistance: 30, dhashDistance: 30, mad: 78, visionScore: 0.12, label: false)
        }
    }

    func probability(phashDistance: Int, dhashDistance: Int, mad: Double, visionScore: Double?) -> Double {
        let x = features(phashDistance: phashDistance, dhashDistance: dhashDistance, mad: mad, visionScore: visionScore)
        lock.lock(); defer { lock.unlock() }
        return sigmoid(dot(state.weights, x))
    }

    func learn(phashDistance: Int, dhashDistance: Int, mad: Double, visionScore: Double?, label: Bool) {
        let x = features(phashDistance: phashDistance, dhashDistance: dhashDistance, mad: mad, visionScore: visionScore)
        let y = label ? 1.0 : 0.0
        lock.lock()
        let p = sigmoid(dot(state.weights, x))
        let error = y - p
        let learningRate = 0.08 / sqrt(Double(max(1, state.examples + 1)))
        for i in 0..<state.weights.count {
            state.weights[i] += learningRate * error * x[i]
            state.weights[i] = max(-12, min(12, state.weights[i]))
        }
        state.examples += 1
        if label { state.positives += 1 } else { state.negatives += 1 }
        let snapshot = state
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func features(phashDistance: Int, dhashDistance: Int, mad: Double, visionScore: Double?) -> [Double] {
        [
            1,
            1 - min(1, Double(phashDistance) / 64.0),
            1 - min(1, Double(dhashDistance) / 64.0),
            1 - min(1, mad / 255.0),
            visionScore ?? 0
        ]
    }

    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func sigmoid(_ x: Double) -> Double {
        if x >= 0 {
            let z = exp(-x)
            return 1 / (1 + z)
        }
        let z = exp(x)
        return z / (1 + z)
    }
}
