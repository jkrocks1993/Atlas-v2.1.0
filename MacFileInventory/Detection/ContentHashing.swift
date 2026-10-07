import Foundation
import CryptoKit

enum ContentHashing {
    /// Cheap identity used only to form candidate buckets. Never a final duplicate decision by itself.
    static func prefixSuffixDigest(url: URL, size: Int64) -> String? {
        guard size > 0 else { return "empty" }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let window = 64 * 1024
        let head = handle.readData(ofLength: window)
        var tail = Data()
        if size > window {
            do {
                try handle.seek(toOffset: UInt64(max(0, size - Int64(window))))
                tail = handle.readData(ofLength: window)
            } catch {
                tail = Data()
            }
        }
        var hasher = SHA256()
        var sizeBE = size.bigEndian
        withUnsafeBytes(of: &sizeBE) { hasher.update(bufferPointer: $0) }
        hasher.update(data: head)
        hasher.update(data: tail)
        return Hex.string(Data(hasher.finalize()))
    }

    static func fullSHA256(url: URL, size: Int64, limitBytes: Int64 = 700_000_000) -> String? {
        if size == 0 { return "empty-sha256" }
        if size > limitBytes {
            return nil
        }
        return try? Hex.sha256File(url: url)
    }
}

struct ImageSignature: Hashable {
    var width: Int
    var height: Int
    var pHash: UInt64
    var dHash: UInt64
    var grid: [UInt8]
    var pixelIdentity: String?

    var aspect: Double {
        guard height > 0 else { return 0 }
        return Double(width) / Double(height)
    }
}

struct VideoSignature: Hashable {
    var duration: Double
    var width: Int
    var height: Int
    var frameHashes: [UInt64]
}

struct PDFSignature: Hashable {
    var pageCount: Int
    var textHash: String?
    var textLength: Int
    var pageHashes: [UInt64]
    var isImageOnly: Bool
    var imageSignatures: [ImageSignature]
}

struct TextSignature: Hashable {
    var contentHash: String
    var length: Int
}

struct ArchiveSignature: Hashable {
    var manifestHash: String
    var entryCount: Int
}
