import Foundation

struct ScanStatistics: Equatable {
    var filesScanned: Int = 0
    var images: Int = 0
    var videos: Int = 0
    var audio: Int = 0
    var pdfs: Int = 0
    var word: Int = 0
    var powerpoint: Int = 0
    var excel: Int = 0
    var zip: Int = 0
    var rar: Int = 0
    var other: Int = 0
    var unknown: Int = 0
    var uncompared: Int = 0

    mutating func add(_ category: FileCategory) {
        filesScanned += 1
        switch category {
        case .images: images += 1
        case .videos: videos += 1
        case .audio: audio += 1
        case .pdfs: pdfs += 1
        case .word: word += 1
        case .powerpoint: powerpoint += 1
        case .excel: excel += 1
        case .zip: zip += 1
        case .rar: rar += 1
        case .other: other += 1
        case .unknown: unknown += 1
        }
    }

    func count(for category: FileCategory) -> Int {
        switch category {
        case .images: return images
        case .videos: return videos
        case .audio: return audio
        case .pdfs: return pdfs
        case .word: return word
        case .powerpoint: return powerpoint
        case .excel: return excel
        case .zip: return zip
        case .rar: return rar
        case .other: return other
        case .unknown: return unknown
        }
    }

    var singleLine: String {
        let parts: [(String, Int)] = [
            ("Files Scanned", filesScanned),
            ("Images", images),
            ("Videos", videos),
            ("Soundtracks", audio),
            ("Documents", pdfs),
            ("Word", word),
            ("Presentations", powerpoint),
            ("Excel", excel),
            ("ZIP", zip),
            ("RAR", rar),
            ("Other", other),
            ("Unknown", unknown),
            ("Uncompared", uncompared)
        ]
        return parts.map { "\($0.0): \(Self.grouped($0.1))" }.joined(separator: " | ")
    }

    private static func grouped(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct ScanSession {
    var id = UUID()
    var location: ScanLocation = .entireMac
    var enabledCategories: Set<FileCategory> = Set(FileCategory.allCases)
    var files: [UUID: FileRecord] = [:]
    var groups: [UUID: DuplicateGroup] = [:]
    var statistics = ScanStatistics()
    var currentPath: String = ""
    var progress: Double = 0
    var phase: ScanPhase = .idle
    var estimatedTotal: Int = 0
}

enum ResultLayout: String, CaseIterable, Identifiable {
    case list
    case tiles
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .tiles: return "Tiles"
        case .large: return "Large"
        }
    }

    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .tiles: return "square.grid.2x2"
        case .large: return "square.grid.2x2.fill"
        }
    }

    var tile: CGFloat {
        switch self {
        case .list: return 0
        case .tiles: return 148
        case .large: return 236
        }
    }
}

struct ListDisplayRecord: Identifiable, Hashable {
    let id: UUID
    let name: String
    let path: String
    let size: Int64
    let modified: Date?
    let isBest: Bool
    let indented: Bool
}

enum ListRow: Identifiable, Hashable {
    case unique(fileID: UUID)
    case best(groupID: UUID, fileID: UUID)
    case member(groupID: UUID, fileID: UUID)
    case separator(groupID: UUID)

    var id: String {
        switch self {
        case .unique(let fileID):
            return "u-\(fileID.uuidString)"
        case .best(let groupID, let fileID):
            return "b-\(groupID.uuidString)-\(fileID.uuidString)"
        case .member(let groupID, let fileID):
            return "m-\(groupID.uuidString)-\(fileID.uuidString)"
        case .separator(let groupID):
            return "s-\(groupID.uuidString)"
        }
    }

    var fileID: UUID? {
        switch self {
        case .unique(let fileID), .best(_, let fileID), .member(_, let fileID):
            return fileID
        case .separator:
            return nil
        }
    }
}

struct MoveSummaryCategory: Identifiable {
    let id = UUID()
    let category: FileCategory
    var uniqueCount: Int
    var duplicateCount: Int
    var total: Int { uniqueCount + duplicateCount }
}

enum EnhancementKind: String, CaseIterable, Identifiable {
    case twoX = "2×"
    case threeX = "3×"
    case fourK = "4K"
    case maximum = "Maximum supported"
    var id: String { rawValue }
}

enum EnhancementQuality: String, CaseIterable, Identifiable {
    case balanced = "Balanced"
    case highest = "Highest Quality"
    case faster = "Faster"
    var id: String { rawValue }
}

struct EnhancementRequest {
    var kind: EnhancementKind = .twoX
    var quality: EnhancementQuality = .highest
    var preserveOriginal: Bool = true
    var createCopy: Bool = true
    var openWhenFinished: Bool = true
}
