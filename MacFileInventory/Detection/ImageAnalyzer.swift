import Foundation
import AppKit
import ImageIO
import CoreGraphics
import Accelerate

enum ImageAnalyzer {
    static func signature(url: URL) -> ImageSignature? {
        guard let cg = loadCGImage(url: url) else { return nil }
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return nil }
        guard let grey32 = luminance(cg, size: 32) else { return nil }
        guard let grey16 = luminance(cg, size: 16) else { return nil }
        let p = dctPHash(grey32)
        let d = dHash(grey32)
        return ImageSignature(
            width: width,
            height: height,
            pHash: p,
            dHash: d,
            grid: grey16,
            pixelIdentity: Hex.sha256(Data(grey32))
        )
    }

    static func areDuplicates(_ a: ImageSignature, _ b: ImageSignature) -> Bool {
        if let pa = a.pixelIdentity, let pb = b.pixelIdentity, pa == pb {
            return true
        }
        guard a.aspect > 0, b.aspect > 0 else { return false }
        let aspectDelta = abs(a.aspect - b.aspect) / max(a.aspect, b.aspect)
        guard aspectDelta <= 0.08 else { return false }
        let ph = Hamming.distance(a.pHash, b.pHash)
        let dh = Hamming.distance(a.dHash, b.dHash)
        guard a.grid.count == 256, b.grid.count == 256 else { return false }
        var acc = 0
        for i in 0..<256 {
            acc += abs(Int(a.grid[i]) - Int(b.grid[i]))
        }
        let mad = Double(acc) / 256.0
        if ph <= 8 && dh <= 8 && mad <= 14 { return true }
        if ph <= 5 && mad <= 18 { return true }
        return false
    }

    static func loadCGImage(url: URL) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
            return thumb
        }
        // Never fall back to decoding the original image at full resolution. A single
        // multi-hundred-megapixel TIFF/RAW can otherwise allocate hundreds of MB or more.
        // The bounded thumbnail is sufficient for the existing comparison logic; if macOS
        // cannot produce it, the file is conservatively treated as Uncompared.
        return nil
    }

    ///  `size × size` luminance, row-major, 0...255.
    static func luminance(_ image: CGImage, size: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: size * size)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels
    }

    /// 64-bit DCT perceptual hash. Not an average-grey hash.
    static func dctPHash(_ grey32: [UInt8]) -> UInt64 {
        precondition(grey32.count == 1024)
        var matrix = [Double](repeating: 0, count: 1024)
        for i in 0..<1024 { matrix[i] = Double(grey32[i]) }
        let dct = dct2D(matrix, n: 32)
        var coeffs: [Double] = []
        coeffs.reserveCapacity(64)
        for y in 0..<8 {
            for x in 0..<8 {
                if x == 0 && y == 0 { continue }
                coeffs.append(dct[y * 32 + x])
            }
        }
        // 63 values; pad median over first 64 low-frequency including a dummy
        while coeffs.count < 64 { coeffs.append(0) }
        let sorted = coeffs.sorted()
        let median = (sorted[31] + sorted[32]) / 2.0
        var hash: UInt64 = 0
        for i in 0..<64 {
            if coeffs[i] > median {
                hash |= (1 << UInt64(i))
            }
        }
        return hash
    }

    static func dHash(_ grey32: [UInt8]) -> UInt64 {
        // Use 8×9 gradient on a downsampled view of the 32×32 plane.
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let left = grey32[(y * 4) * 32 + (x * 4)]
                let right = grey32[(y * 4) * 32 + min(31, x * 4 + 4)]
                if left < right {
                    hash |= (1 << bit)
                }
                bit += 1
            }
        }
        return hash
    }

    /// Separable DCT-II.
    private static func dct2D(_ input: [Double], n: Int) -> [Double] {
        var rows = [Double](repeating: 0, count: n * n)
        var tmp = [Double](repeating: 0, count: n)
        var out = [Double](repeating: 0, count: n)
        for y in 0..<n {
            for x in 0..<n { tmp[x] = input[y * n + x] }
            dct1D(tmp, result: &out)
            for x in 0..<n { rows[y * n + x] = out[x] }
        }
        var cols = [Double](repeating: 0, count: n * n)
        for x in 0..<n {
            for y in 0..<n { tmp[y] = rows[y * n + x] }
            dct1D(tmp, result: &out)
            for y in 0..<n { cols[y * n + x] = out[y] }
        }
        return cols
    }

    private static func dct1D(_ input: [Double], result: inout [Double]) {
        let n = input.count
        let factor = Double.pi / Double(n)
        for k in 0..<n {
            var sum = 0.0
            for x in 0..<n {
                sum += input[x] * cos(factor * (Double(x) + 0.5) * Double(k))
            }
            result[k] = sum
        }
    }
}
