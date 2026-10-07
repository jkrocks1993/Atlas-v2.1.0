import Foundation
import AppKit

enum FileOperations {
    @discardableResult
    static func trash(urls: [URL]) throws -> [URL] {
        var trashed: [URL] = []
        for url in urls {
            var out: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &out)
            if let outURL = out as URL? {
                trashed.append(outURL)
            }
        }
        return trashed
    }

    static func move(urls: [URL], to directory: URL) throws -> [URL] {
        var moved: [URL] = []
        let fm = FileManager.default
        for url in urls {
            let dest = Collision.uniqueURL(in: directory, preferredName: url.lastPathComponent)
            try fm.moveItem(at: url, to: dest)
            moved.append(dest)
        }
        return moved
    }

    static func summarize(records: [FileRecord]) -> [MoveSummaryCategory] {
        var map: [FileCategory: (u: Int, d: Int)] = [:]
        for rec in records {
            var pair = map[rec.category] ?? (0, 0)
            if rec.comparisonStatus == .duplicate {
                pair.d += 1
            } else {
                pair.u += 1
            }
            map[rec.category] = pair
        }
        return FileCategory.allCases.compactMap { cat in
            guard let pair = map[cat], pair.u + pair.d > 0 else { return nil }
            return MoveSummaryCategory(category: cat, uniqueCount: pair.u, duplicateCount: pair.d)
        }
    }
}
