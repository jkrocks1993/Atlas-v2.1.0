import Foundation
import UniformTypeIdentifiers

struct FileRecord: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var category: FileCategory
    var size: Int64
    var created: Date?
    var modified: Date?
    var uti: String?
    var contentFingerprint: String?
    var perceptualSignature: String?
    var extraSignals: [String: String]
    var comparisonStatus: ComparisonStatus
    var groupID: UUID?
    var isBest: Bool
    var decodeFailed: Bool
    var contentKind: ContentKind

    init(
        id: UUID = UUID(),
        url: URL,
        category: FileCategory,
        size: Int64 = 0,
        created: Date? = nil,
        modified: Date? = nil,
        uti: String? = nil,
        contentFingerprint: String? = nil,
        perceptualSignature: String? = nil,
        extraSignals: [String: String] = [:],
        comparisonStatus: ComparisonStatus = .pending,
        groupID: UUID? = nil,
        isBest: Bool = false,
        decodeFailed: Bool = false,
        contentKind: ContentKind = .other
    ) {
        self.id = id
        self.url = url
        self.category = category
        self.size = size
        self.created = created
        self.modified = modified
        self.uti = uti
        self.contentFingerprint = contentFingerprint
        self.perceptualSignature = perceptualSignature
        self.extraSignals = extraSignals
        self.comparisonStatus = comparisonStatus
        self.groupID = groupID
        self.isBest = isBest
        self.decodeFailed = decodeFailed
        self.contentKind = contentKind
    }

    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var ext: String { url.pathExtension.lowercased() }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileRecord, rhs: FileRecord) -> Bool {
        lhs.id == rhs.id
    }
}

struct DuplicateGroup: Identifiable, Hashable {
    let id: UUID
    var category: FileCategory
    var memberIDs: [UUID]
    var bestID: UUID

    init(id: UUID = UUID(), category: FileCategory, memberIDs: [UUID], bestID: UUID) {
        self.id = id
        self.category = category
        self.memberIDs = memberIDs
        self.bestID = bestID
    }
}

enum ScanLocation: Equatable {
    case entireMac
    case folder(URL)

    var displayPath: String {
        switch self {
        case .entireMac:
            return "/"
        case .folder(let url):
            return url.path
        }
    }

    var displayLabel: String {
        switch self {
        case .entireMac:
            return "Entire Mac"
        case .folder(let url):
            return url.path
        }
    }

    var rootURL: URL {
        switch self {
        case .entireMac:
            return URL(fileURLWithPath: "/", isDirectory: true)
        case .folder(let url):
            return url
        }
    }

    var isEntireMac: Bool {
        if case .entireMac = self { return true }
        return false
    }
}

enum SortField: String, CaseIterable, Identifiable {
    case name, size, dateModified, dateCreated, fileType
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .fileType: return "File Type"
        }
    }
}

enum SortDirection: String, CaseIterable, Identifiable {
    case ascending, descending
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ascending: return "Ascending"
        case .descending: return "Descending"
        }
    }
}

enum ResultSubtab: String, Hashable {
    case unique
    case duplicates
    case uncompared
}
