import Foundation
import PDFKit
import CoreGraphics

enum PDFAnalyzer {
    static func signature(url: URL) -> PDFSignature? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let pageCount = doc.pageCount
        guard pageCount > 0 else { return nil }

        var text = ""
        text.reserveCapacity(4096)
        for i in 0..<pageCount {
            if let pageText = doc.page(at: i)?.string {
                text.append(pageText)
                text.append("\n")
            }
        }
        let normalized = normalize(text)
        let textLength = normalized.count
        let isImageOnly = textLength < 80

        var textHash: String?
        if textLength >= 40 {
            textHash = Hex.sha256(Data(normalized.utf8))
        }

        var pageHashes: [UInt64] = []
        var imageSignatures: [ImageSignature] = []
        let pagesToRender = min(pageCount, isImageOnly ? pageCount : min(pageCount, 4))
        for i in 0..<pagesToRender {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(2.0, 512.0 / max(bounds.width, 1))
            let size = CGSize(width: max(32, bounds.width * scale), height: max(32, bounds.height * scale))
            guard let img = raster(page: page, size: size) else { continue }
            if let grey = ImageAnalyzer.luminance(img, size: 32) {
                pageHashes.append(ImageAnalyzer.dctPHash(grey))
            }
            if isImageOnly, let sig = imageSignature(from: img) {
                imageSignatures.append(sig)
            }
        }

        return PDFSignature(
            pageCount: pageCount,
            textHash: textHash,
            textLength: textLength,
            pageHashes: pageHashes,
            isImageOnly: isImageOnly,
            imageSignatures: imageSignatures
        )
    }

    static func areDuplicates(_ a: PDFSignature, _ b: PDFSignature) -> Bool {
        guard a.pageCount == b.pageCount, a.pageCount > 0 else { return false }
        if let ah = a.textHash, let bh = b.textHash, a.textLength >= 200, b.textLength >= 200 {
            return ah == bh
        }
        guard a.pageHashes.count == b.pageHashes.count, !a.pageHashes.isEmpty else { return false }
        var matches = 0
        for i in 0..<a.pageHashes.count {
            if Hamming.distance(a.pageHashes[i], b.pageHashes[i]) <= 3 {
                matches += 1
            }
        }
        return matches == a.pageHashes.count
    }

    private static func normalize(_ text: String) -> String {
        let mapped = text.lowercased().map { ch -> Character in
            ch.isWhitespace || ch.isNewline ? " " : ch
        }
        let collapsed = String(mapped).split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return collapsed
    }

    private static func raster(page: PDFPage, size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let bounds = page.bounds(for: .mediaBox)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(w) / max(bounds.width, 1), y: -CGFloat(h) / max(bounds.height, 1))
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private static func imageSignature(from cg: CGImage) -> ImageSignature? {
        guard let grey32 = ImageAnalyzer.luminance(cg, size: 32) else { return nil }
        guard let grey16 = ImageAnalyzer.luminance(cg, size: 16) else { return nil }
        return ImageSignature(
            width: cg.width,
            height: cg.height,
            pHash: ImageAnalyzer.dctPHash(grey32),
            dHash: ImageAnalyzer.dHash(grey32),
            grid: grey16,
            pixelIdentity: Hex.sha256(Data(grey32))
        )
    }
}
