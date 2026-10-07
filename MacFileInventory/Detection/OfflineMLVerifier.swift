import Foundation
import Vision
import CoreGraphics

/// Fully local Vision/Core ML verification.
///
/// Vision's feature-print model runs on the Mac. No model is downloaded by ATLAS
/// and no image bytes leave the process. This verifier is deliberately used only
/// for ambiguous candidates; exact hashes and deterministic signatures remain authoritative.
enum OfflineMLVerifier {
    struct Result {
        let distance: Float
        let probability: Double
    }

    static func compare(_ lhs: URL, _ rhs: URL) -> Result? {
        guard let a = makeObservation(url: lhs), let b = makeObservation(url: rhs) else { return nil }
        var distance: Float = .greatestFiniteMagnitude
        do {
            try a.computeDistance(&distance, to: b)
        } catch {
            return nil
        }
        // Vision feature-print distances are model/version dependent. The probability
        // here is a conservative monotonic score, not a claim of calibrated probability.
        let d = Double(max(0, distance))
        let score = max(0, min(1, 1.0 - d / 1.25))
        return Result(distance: distance, probability: score)
    }

    static func likelyDuplicate(_ result: Result, minimumScore: Double = 0.84) -> Bool {
        result.probability >= minimumScore
    }

    private static func makeObservation(url: URL) -> VNFeaturePrintObservation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 768,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCache: false
                ] as CFDictionary
              ) else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }
}
