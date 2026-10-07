import Foundation
import Compression

enum ArchiveAnalyzer {
    static func zipSignature(url: URL) -> ArchiveSignature? {
        guard let zip = ZipReader(url: url) else { return nil }
        var lines: [String] = []
        lines.reserveCapacity(zip.entries.count)
        for entry in zip.entries.sorted(by: { $0.name < $1.name }) {
            let name = normalizePath(entry.name)
            if name.hasPrefix("__macosx/") || name.hasSuffix(".ds_store") { continue }
            lines.append("\(name)|\(entry.uncompressedSize)|\(entry.crc32)")
        }
        guard !lines.isEmpty else { return nil }
        let payload = lines.joined(separator: "\n")
        return ArchiveSignature(manifestHash: Hex.sha256(Data(payload.utf8)), entryCount: lines.count)
    }

    /// Conservative RAR4 header walk. RAR5 / encrypted / solid archives return nil → Uncompared.
    static func rarSignature(url: URL) -> ArchiveSignature? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 8)
        guard head.count >= 7 else { return nil }
        let bytes = [UInt8](head)
        // RAR4: 52 61 72 21 1A 07 00
        // RAR5: 52 61 72 21 1A 07 01 00
        guard bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) else { return nil }
        if bytes.count >= 7 && bytes[6] == 0x01 {
            return nil
        }
        var entries: [String] = []
        var guardCounter = 0
        while guardCounter < 20_000 {
            guardCounter += 1
            let hdr = handle.readData(ofLength: 7)
            if hdr.count < 7 { break }
            let h = [UInt8](hdr)
            let type = h[2]
            let flags = UInt16(h[3]) | (UInt16(h[4]) << 8)
            let size = UInt16(h[5]) | (UInt16(h[6]) << 8)
            let extra = Int(size) - 7
            if extra < 0 { return nil }
            let rest = handle.readData(ofLength: extra)
            if rest.count < extra { return nil }
            if type == 0x74 { // file header
                guard rest.count >= 25 else { return nil }
                let r = [UInt8](rest)
                let unpSize = u32(r, 1)
                let nameSize = Int(UInt16(r[21]) | (UInt16(r[22]) << 8))
                guard rest.count >= 25 + nameSize else { return nil }
                let nameData = rest.subdata(in: 25..<(25 + nameSize))
                let name = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: .isoLatin1)
                    ?? "entry"
                let highUnpack: UInt32 = (flags & 0x0100) != 0 && rest.count >= 25 + nameSize + 8
                    ? u32([UInt8](rest), 25 + nameSize + 4)
                    : 0
                let fullSize = (UInt64(highUnpack) << 32) | UInt64(unpSize)
                entries.append("\(normalizePath(name))|\(fullSize)")
                let packSize = u32(r, 0)
                let highPack: UInt32 = (flags & 0x0100) != 0 && rest.count >= 25 + nameSize + 4
                    ? u32([UInt8](rest), 25 + nameSize)
                    : 0
                let skip = (UInt64(highPack) << 32) | UInt64(packSize)
                let current = handle.offsetInFile
                handle.seek(toFileOffset: current + skip)
            } else if type == 0x7B { // end
                break
            }
        }
        guard !entries.isEmpty else { return nil }
        let payload = entries.sorted().joined(separator: "\n")
        return ArchiveSignature(manifestHash: Hex.sha256(Data(payload.utf8)), entryCount: entries.count)
    }

    private static func normalizePath(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    private static func u32(_ r: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < r.count else { return 0 }
        return UInt32(r[offset])
            | (UInt32(r[offset + 1]) << 8)
            | (UInt32(r[offset + 2]) << 16)
            | (UInt32(r[offset + 3]) << 24)
    }
}

struct ZipEntryInfo {
    var name: String
    var compressedSize: UInt64
    var uncompressedSize: UInt64
    var crc32: UInt32
    var compression: UInt16
    var localHeaderOffset: UInt64
}

/// Minimal ZIP central-directory reader. No third-party library.
final class ZipReader {
    let entries: [ZipEntryInfo]
    let entryNames: [String]
    private let url: URL

    init?(url: URL) {
        self.url = url
        guard let parsed = ZipReader.readCentralDirectory(url: url) else { return nil }
        self.entries = parsed
        self.entryNames = parsed.map(\.name)
    }

    func data(forEntry name: String) -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return extract(entry)
    }

    func data(forEntrySuffix suffix: String) -> Data? {
        let lower = suffix.lowercased()
        guard let entry = entries.first(where: { $0.name.lowercased().hasSuffix(lower) }) else { return nil }
        return extract(entry)
    }

    private func extract(_ entry: ZipEntryInfo) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        handle.seek(toFileOffset: entry.localHeaderOffset)
        let local = handle.readData(ofLength: 30)
        guard local.count == 30 else { return nil }
        let b = [UInt8](local)
        guard b[0] == 0x50, b[1] == 0x4B, b[2] == 0x03, b[3] == 0x04 else { return nil }
        let nameLen = Int(UInt16(b[26]) | (UInt16(b[27]) << 8))
        let extraLen = Int(UInt16(b[28]) | (UInt16(b[29]) << 8))
        // Resource guard: never allocate an arbitrarily large compressed archive entry.
        // The comparison logic is unchanged; unsupported/oversized entries become Uncompared.
        let maxEntryBytes: UInt64 = 32 * 1024 * 1024
        guard entry.compressedSize <= maxEntryBytes, entry.uncompressedSize <= maxEntryBytes else { return nil }
        handle.seek(toFileOffset: entry.localHeaderOffset + 30 + UInt64(nameLen + extraLen))
        let payload = handle.readData(ofLength: Int(entry.compressedSize))
        if entry.compression == 0 {
            return payload
        }
        if entry.compression == 8 {
            return Self.inflate(payload, expected: Int(entry.uncompressedSize))
        }
        return nil
    }

    private static func inflate(_ data: Data, expected: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        if let out = decodeZlib(data, expected: expected) { return out }
        var wrapped = Data([0x78, 0x9C])
        wrapped.append(data)
        return decodeZlib(wrapped, expected: expected)
    }

    private static func decodeZlib(_ data: Data, expected: Int) -> Data? {
        let dstSize = max(expected > 0 ? expected : max(data.count * 8, 4096), 1024)
        var destination = Data(count: dstSize)
        let written = destination.withUnsafeMutableBytes { dstPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                guard let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcPtr.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(dst, dstSize, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        destination.count = written
        return destination
    }

    private static func readCentralDirectory(url: URL) -> [ZipEntryInfo]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs?[.size] as? NSNumber else { return nil }
        let fileSize = size.uint64Value
        guard fileSize >= 22 else { return nil }
        let maxComment: UInt64 = 65535
        let readLen = min(fileSize, 22 + maxComment)
        handle.seek(toFileOffset: fileSize - readLen)
        let tail = handle.readData(ofLength: Int(readLen))
        guard let eocd = findEOCD(tail) else { return nil }
        let cdOffset = eocd.offset
        let cdSize = eocd.size
        guard cdSize <= 64 * 1024 * 1024 else { return nil }
        handle.seek(toFileOffset: cdOffset)
        let cd = handle.readData(ofLength: Int(cdSize))
        return parseCentralDirectory(cd)
    }

    private struct EOCD {
        var offset: UInt64
        var size: UInt64
    }

    private static func findEOCD(_ tail: Data) -> EOCD? {
        let bytes = [UInt8](tail)
        if bytes.count < 22 { return nil }
        var i = bytes.count - 22
        while i >= 0 {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                let cdSize = u32(bytes, i + 12)
                let cdOff = u32(bytes, i + 16)
                return EOCD(offset: UInt64(cdOff), size: UInt64(cdSize))
            }
            if i == 0 { break }
            i -= 1
        }
        return nil
    }

    private static func parseCentralDirectory(_ data: Data) -> [ZipEntryInfo]? {
        let b = [UInt8](data)
        var idx = 0
        var entries: [ZipEntryInfo] = []
        while idx + 46 <= b.count {
            guard b[idx] == 0x50, b[idx + 1] == 0x4B, b[idx + 2] == 0x01, b[idx + 3] == 0x02 else {
                break
            }
            let compression = UInt16(b[idx + 10]) | (UInt16(b[idx + 11]) << 8)
            let crc = u32(b, idx + 16)
            let compSize = u32(b, idx + 20)
            let uncompSize = u32(b, idx + 24)
            let nameLen = Int(UInt16(b[idx + 28]) | (UInt16(b[idx + 29]) << 8))
            let extraLen = Int(UInt16(b[idx + 30]) | (UInt16(b[idx + 31]) << 8))
            let commentLen = Int(UInt16(b[idx + 32]) | (UInt16(b[idx + 33]) << 8))
            let localOff = u32(b, idx + 42)
            let nameStart = idx + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= b.count else { return entries }
            let nameData = Data(b[nameStart..<nameEnd])
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? "entry"
            entries.append(
                ZipEntryInfo(
                    name: name,
                    compressedSize: UInt64(compSize),
                    uncompressedSize: UInt64(uncompSize),
                    crc32: crc,
                    compression: compression,
                    localHeaderOffset: UInt64(localOff)
                )
            )
            idx = nameEnd + extraLen + commentLen
        }
        return entries
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}
