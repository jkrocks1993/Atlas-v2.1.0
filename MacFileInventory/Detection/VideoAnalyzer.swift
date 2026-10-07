import Foundation
import AVFoundation
import CoreGraphics

enum VideoAnalyzer {
    static let samplePercents: [Double] = [0.12, 0.38, 0.62, 0.84]

    static func signature(url: URL) -> VideoSignature? {
        let asset = AVURLAsset(url: url)
        let ready = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
            ready.signal()
        }
        _ = ready.wait(timeout: .now() + 12)

        var durationError: NSError?
        let durStatus = asset.statusOfValue(forKey: "duration", error: &durationError)
        let duration = CMTimeGetSeconds(asset.duration)
        let usableDuration = (durStatus == .loaded && duration.isFinite && duration > 0) ? duration : 0

        var trackError: NSError?
        _ = asset.statusOfValue(forKey: "tracks", error: &trackError)
        let tracks = asset.tracks(withMediaType: .video)
        let track = tracks.first
        var width = 0
        var height = 0
        if let track {
            let size = track.naturalSize.applying(track.preferredTransform)
            width = Int(abs(size.width.rounded()))
            height = Int(abs(size.height.rounded()))
        }

        var hashes: [UInt64] = []
        if usableDuration > 0 {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1.2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1.2, preferredTimescale: 600)
            generator.maximumSize = CGSize(width: 240, height: 240)

            for percent in samplePercents {
                let t = min(max(usableDuration * percent, 0.05), max(0.05, usableDuration - 0.05))
                let time = CMTime(seconds: t, preferredTimescale: 600)
                var actual = CMTime.zero
                guard let cg = try? generator.copyCGImage(at: time, actualTime: &actual) else { continue }
                if let grey = ImageAnalyzer.luminance(cg, size: 32) {
                    hashes.append(ImageAnalyzer.dctPHash(grey))
                }
            }
        }

        // Duration-only still counts as compared so the file is Unique, not Uncompared.
        if usableDuration <= 0 && hashes.isEmpty && width == 0 {
            return nil
        }
        return VideoSignature(
            duration: max(usableDuration, 0),
            width: width,
            height: height,
            frameHashes: hashes
        )
    }

    static func areDuplicates(_ a: VideoSignature, _ b: VideoSignature) -> Bool {
        if a.duration > 0, b.duration > 0 {
            let durDelta = abs(a.duration - b.duration)
            let durTol = max(0.35, max(a.duration, b.duration) * 0.02)
            guard durDelta <= durTol else { return false }
        }
        let n = min(a.frameHashes.count, b.frameHashes.count)
        if n >= 2 {
            var matches = 0
            for i in 0..<n {
                if Hamming.distance(a.frameHashes[i], b.frameHashes[i]) <= 8 {
                    matches += 1
                }
            }
            let need = max(2, (n * 2) / 3)
            return matches >= need
        }
        return false
    }
}

enum AudioAnalyzer {
    static func key(url: URL, size: Int64) -> String? {
        let asset = AVURLAsset(url: url)
        let ready = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["duration"]) { ready.signal() }
        _ = ready.wait(timeout: .now() + 6)
        let duration = CMTimeGetSeconds(asset.duration)
        let durPart = (duration.isFinite && duration > 0) ? String(Int((duration * 10).rounded())) : "na"
        let digest = ContentHashing.prefixSuffixDigest(url: url, size: size) ?? "na"
        return "\(durPart):\(digest)"
    }
}
