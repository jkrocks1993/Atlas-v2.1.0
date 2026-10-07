import Foundation
import AppKit
import CryptoKit

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

enum DateFormat {
    static func string(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

enum Collision {
    static func uniqueURL(in directory: URL, preferredName: String) -> URL {
        let ns = preferredName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var index = 0
        var candidate = directory.appendingPathComponent(preferredName)
        while FileManager.default.fileExists(atPath: candidate.path) {
            index += 1
            let name: String
            if ext.isEmpty {
                name = "\(base) (\(index))"
            } else {
                name = "\(base) (\(index)).\(ext)"
            }
            candidate = directory.appendingPathComponent(name)
        }
        return candidate
    }
}

enum Hex {
    static func string(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> String {
        string(Data(SHA256.hash(data: data)))
    }

    static func sha256File(url: URL, limit: Int64? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int64.max
        while remaining > 0 {
            let chunk = min(remaining, 1024 * 1024)
            let data = handle.readData(ofLength: Int(chunk))
            if data.isEmpty { break }
            hasher.update(data: data)
            remaining -= Int64(data.count)
        }
        return string(Data(hasher.finalize()))
    }
}

enum Hamming {
    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

enum PathRules {
    static let entireMacSkipPrefixes = [
        "/dev",
        "/net",
        "/home",
        "/Network",
        "/private/var/vm",
        "/System/Volumes/Preboot",
        "/System/Volumes/Update",
        "/System/Volumes/VM",
        "/System/Library/Sounds",
        "/System/Library/Audio",
        "/.Spotlight-V100",
        "/.fseventsd",
        "/.DocumentRevisions-V100",
        "/.TemporaryItems",
        "/private/var/db/diagnostics",
        "/private/var/log/DiagnosticMessages"
    ]

    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "osax", "plugin", "xpc",
        "playground", "xcodeproj", "xcworkspace", "photoslibrary"
    ]

    static func shouldSkip(path: String, entireMac: Bool) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/library/caches")
            || lower.contains("/.trash")
            || lower.contains("/node_modules/")
            || lower.contains("/.git/")
            || lower.contains("/deriveddata/") {
            return true
        }

        // Thumbnail/cache trees are skipped only in Library/Application Support/cache
        // contexts, not user-created folders named "Thumbnails" in Pictures/Desktop.
        let appAssetContext = lower.contains("/library/") || lower.contains("/application support/")
        if appAssetContext {
            let generatedAssetFolders = [
                "/thumbnails/", "/thumbnailcache/", "/thumbnail cache/",
                "/quicklook/", "/quick look/", "/iconservices/", "/com.apple.iconservices/"
            ]
            if generatedAssetFolders.contains(where: { lower.contains($0) }) { return true }
        }

        // Ignore image/audio assets stored in Application Support (app artwork, bundled
        // soundtrack/default sounds), but do not prune Application Support wholesale and
        // do not exclude the user's Music, Desktop, Documents, or Downloads.
        if lower.contains("/library/application support/") || lower.contains("/application support/") {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            let appAssetExtensions: Set<String> = [
                "png", "jpg", "jpeg", "jpe", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "avif", "icns",
                "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "ogg", "opus", "mid", "midi"
            ]
            if appAssetExtensions.contains(ext) { return true }
        }

        // Standalone macOS icon resources are not user photographs or documents.
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "icns" { return true }

        if entireMac {
            for prefix in entireMacSkipPrefixes {
                if path == prefix || path.hasPrefix(prefix + "/") { return true }
            }
        }
        return false
    }

    static func isPackage(_ url: URL) -> Bool {
        packageExtensions.contains(url.pathExtension.lowercased())
    }
}

extension NSOpenPanel {
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose a folder, volume, or mounted drive to scan."
        panel.prompt = "Select Folder"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Move"
        panel.message = "Choose a destination folder."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
