import Foundation
import UniformTypeIdentifiers
import CoreServices
import PDFKit
import ImageIO

enum TypeDetector {
    static func category(for url: URL) -> FileCategory {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .typeIdentifierKey])
        let uti = values?.contentType ?? UTType(values?.typeIdentifier ?? "")
        if let uti {
            if matchesImage(uti, url: url) { return .images }
            if matchesVideo(uti, url: url) { return .videos }
            if matchesAudio(uti, url: url) { return .audio }
            if uti.conforms(to: .pdf) || url.pathExtension.lowercased() == "pdf" {
                return isImageOnlyPDF(url) ? .images : .pdfs
            }
            if url.pathExtension.lowercased() == "epub" || uti.identifier.contains("epub") {
                return .pdfs
            }
            if matchesWord(uti, url: url) { return .word }
            if matchesPowerPoint(uti, url: url) { return .powerpoint }
            if matchesExcel(uti, url: url) { return .excel }
            if matchesZip(uti, url: url) { return .zip }
            if matchesRar(uti, url: url) { return .rar }
        }
        if let sniffed = sniffByHeader(url) { return sniffed }
        if url.pathExtension.isEmpty { return .unknown }
        return .other
    }

    static func utiString(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.typeIdentifierKey])
        return values?.typeIdentifier
    }

    private static func matchesImage(_ uti: UTType, url: URL) -> Bool {
        if uti.conforms(to: .image) { return true }
        let ext = url.pathExtension.lowercased()
        let known = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "jp2", "j2k", "ico", "icns"]
        return known.contains(ext)
    }

    private static func matchesAudio(_ uti: UTType, url: URL) -> Bool {
        if uti.conforms(to: .audio) { return true }
        let ext = url.pathExtension.lowercased()
        let known = ["mp3", "wav", "flac", "aac", "m4a", "aiff", "aif", "ogg", "oga", "wma", "opus", "alac", "caf", "au"]
        return known.contains(ext)
    }

    private static func matchesVideo(_ uti: UTType, url: URL) -> Bool {
        if uti.conforms(to: .movie) || uti.conforms(to: .video) || uti.conforms(to: .quickTimeMovie) || uti.conforms(to: .mpeg4Movie) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        let known = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "mpg", "mpeg", "wmv"]
        return known.contains(ext)
    }

    private static func matchesWord(_ uti: UTType, url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["doc", "docx", "pages", "rtf"].contains(ext) { return true }
        if uti.identifier.contains("wordprocessing") { return true }
        if uti.identifier.contains("msword") { return true }
        return false
    }

    private static func matchesPowerPoint(_ uti: UTType, url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["ppt", "pptx", "key"].contains(ext) { return true }
        if uti.identifier.contains("presentation") { return true }
        return false
    }

    private static func matchesExcel(_ uti: UTType, url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["xls", "xlsx", "xlsm", "numbers", "csv"].contains(ext) { return true }
        if uti.identifier.contains("spreadsheet") { return true }
        return false
    }

    private static func matchesZip(_ uti: UTType, url: URL) -> Bool {
        if uti.conforms(to: .zip) { return true }
        return url.pathExtension.lowercased() == "zip"
    }

    private static func matchesRar(_ uti: UTType, url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "rar" || uti.identifier.lowercased().contains("rar")
    }

    /// Magic-byte sniff as a last resort so extension-less files can still be categorized.
    static func sniffByHeader(_ url: URL) -> FileCategory? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: 16)
        guard let data, data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .images }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .images }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return .images }
        if bytes.count >= 12 && Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return .videos } // ftyp
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .videos } // EBML / MKV / WebM
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) { return .videos } // RIFF AVI
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return isImageOnlyPDF(url) ? .images : .pdfs
        }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            // ZIP container — distinguish OOXML vs plain zip by inspecting names later; default zip
            let ext = url.pathExtension.lowercased()
            if ext == "docx" || ext == "doc" { return .word }
            if ext == "pptx" || ext == "ppt" { return .powerpoint }
            if ext == "xlsx" || ext == "xls" { return .excel }
            return .zip
        }
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21]) { return .rar }
        return nil
    }

    /// Image-only PDFs belong in the Images tab. Text PDFs stay in PDFs.
    static func isImageOnlyPDF(_ url: URL) -> Bool {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return false }
        // Books and long scans stay Documents even if OCR text is empty.
        if doc.pageCount > 8 { return false }
        var text = ""
        let limit = min(doc.pageCount, 4)
        for i in 0..<limit {
            text += doc.page(at: i)?.string ?? ""
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count < 80
    }
}

enum ContentKindDetector {
    static func kind(url: URL, category: FileCategory) -> ContentKind {
        if isScreenCapture(url) { return .screenshot }
        if category == .images, hasCameraEXIF(url) { return .photo }
        return .other
    }

    static func isScreenCapture(_ url: URL) -> Bool {
        guard let item = NSMetadataItem(url: url) else { return false }
        let raw = item.value(forAttribute: "kMDItemIsScreenCapture")
        if let flag = raw as? Bool { return flag }
        if let number = raw as? NSNumber { return number.boolValue }
        return false
    }

    static func hasCameraEXIF(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if tiff[kCGImagePropertyTIFFMake] != nil { return true }
            if tiff[kCGImagePropertyTIFFModel] != nil { return true }
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if exif[kCGImagePropertyExifLensModel] != nil { return true }
        }
        return false
    }
}
