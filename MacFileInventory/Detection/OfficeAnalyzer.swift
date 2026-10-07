import Foundation
import Compression

enum OfficeAnalyzer {
    static func signature(url: URL, category: FileCategory) -> TextSignature? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "docx", "pptx", "xlsx", "xlsm":
            return ooxmlSignature(url: url, category: category)
        case "epub":
            return epubSignature(url: url)
        case "pages", "key", "numbers":
            return iWorkHint(url: url)
        case "doc", "ppt", "xls", "rtf":
            return nil
        default:
            return ooxmlSignature(url: url, category: category)
        }
    }

    private static func ooxmlSignature(url: URL, category: FileCategory) -> TextSignature? {
        guard let zip = ZipReader(url: url) else { return nil }
        var pieces: [String] = []
        switch category {
        case .word:
            if let data = zip.data(forEntrySuffix: "word/document.xml") {
                pieces.append(stripXML(data))
            }
        case .powerpoint:
            let slides = zip.entryNames
                .filter { $0.lowercased().contains("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted()
            for name in slides {
                if let data = zip.data(forEntry: name) {
                    pieces.append(stripXML(data))
                }
            }
        case .excel:
            if let data = zip.data(forEntrySuffix: "xl/sharedStrings.xml") {
                pieces.append(stripXML(data))
            }
            let sheets = zip.entryNames
                .filter { $0.lowercased().contains("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted()
            for name in sheets {
                if let data = zip.data(forEntry: name) {
                    pieces.append(stripXML(data))
                }
            }
        default:
            return nil
        }
        let joined = pieces.joined(separator: "\n")
        let normalized = normalize(joined)
        guard normalized.count >= 40 else { return nil }
        return TextSignature(contentHash: Hex.sha256(Data(normalized.utf8)), length: normalized.count)
    }

    static func epubSignature(url: URL) -> TextSignature? {
        guard let zip = ZipReader(url: url) else { return nil }
        var acc = ""
        for name in zip.entryNames {
            let lower = name.lowercased()
            guard lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm") || lower.hasSuffix(".xml") else { continue }
            if let data = zip.data(forEntry: name), data.count < 2_000_000 {
                acc += stripXML(data)
            }
        }
        let normalized = normalize(acc)
        guard normalized.count >= 40 else { return nil }
        return TextSignature(contentHash: Hex.sha256(Data(normalized.utf8)), length: normalized.count)
    }

    /// iWork files are ZIP containers but internals vary; only hash when we find preview/text-ish XML.
    private static func iWorkHint(url: URL) -> TextSignature? {
        guard let zip = ZipReader(url: url) else { return nil }
        var acc = ""
        for name in zip.entryNames where name.hasSuffix(".xml") || name.hasSuffix(".txt") {
            if let data = zip.data(forEntry: name), data.count < 2_000_000 {
                acc += stripXML(data)
            }
        }
        let normalized = normalize(acc)
        guard normalized.count >= 80 else { return nil }
        return TextSignature(contentHash: Hex.sha256(Data(normalized.utf8)), length: normalized.count)
    }

    private static func stripXML(_ data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ""
        }
        var out = ""
        out.reserveCapacity(raw.count)
        var inTag = false
        for ch in raw {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; out.append(" "); continue }
            if !inTag { out.append(ch) }
        }
        return out
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.map { $0.isWhitespace || $0.isNewline ? Character(" ") : $0 }
        return String(mapped).split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }
}
