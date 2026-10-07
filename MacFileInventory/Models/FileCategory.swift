import Foundation
import UniformTypeIdentifiers

enum FileCategory: String, CaseIterable, Identifiable, Codable, Hashable {
    case images
    case videos
    case audio
    case pdfs
    case word
    case powerpoint
    case excel
    case zip
    case rar
    case other
    case unknown

    var id: String { rawValue }

    static var uiCases: [FileCategory] {
        allCases
    }

    var displayName: String {
        switch self {
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Soundtracks"
        case .pdfs: return "Documents"
        case .word: return "Word"
        case .powerpoint: return "Presentations"
        case .excel: return "Excel"
        case .zip: return "ZIP"
        case .rar: return "RAR"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }

    var sortIndex: Int {
        switch self {
        case .images: return 0
        case .videos: return 1
        case .audio: return 2
        case .pdfs: return 3
        case .word: return 4
        case .powerpoint: return 5
        case .excel: return 6
        case .zip: return 7
        case .rar: return 8
        case .other: return 9
        case .unknown: return 10
        }
    }
}

enum ComparisonStatus: String, Codable, Hashable {
    case pending
    case unique
    case duplicate
    case uncompared
}

enum ScanPhase: String {
    case idle
    case scanning
    case paused
    case completed
    case stopped
}

enum ContentKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case screenshot
    case photo
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .screenshot: return "Screenshots"
        case .photo: return "Photos"
        case .other: return "Other"
        }
    }
}
