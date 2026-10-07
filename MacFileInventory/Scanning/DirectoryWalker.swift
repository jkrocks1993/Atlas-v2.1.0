import Foundation

struct WalkedFile {
    let url: URL
    let size: Int64
    let created: Date?
    let modified: Date?
    let uti: String?
}

/// Recursive, volume-aware enumerator. Read-only.
final class DirectoryWalker: @unchecked Sendable {
    private let fileManager = FileManager.default

    func walk(
        location: ScanLocation,
        enabled: Set<FileCategory>,
        control: ScanControl,
        onFile: (WalkedFile) -> Void,
        onPath: (String) -> Void
    ) throws {
        let root = location.rootURL
        let entireMac = location.isEntireMac
        let rootVolume = volumeID(of: root)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isReadableKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .typeIdentifierKey,
                .volumeIdentifierKey,
                .isPackageKey
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        while let item = enumerator.nextObject() as? URL {
            if control.isStopped { return }
            control.waitIfPaused()
            if control.isStopped { return }

            let path = item.path
            onPath(path)

            if PathRules.shouldSkip(path: path, entireMac: entireMac) {
                enumerator.skipDescendants()
                continue
            }

            let values = try? item.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isReadableKey,
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
                .typeIdentifierKey,
                .volumeIdentifierKey,
                .isPackageKey
            ])

            if entireMac, let vid = values?.volumeIdentifier, let rootVolume, !Self.sameVolume(vid, rootVolume) {
                enumerator.skipDescendants()
                continue
            }

            if values?.isSymbolicLink == true {
                continue
            }

            // Application/package internals (icons, sounds, frameworks, plugins, etc.)
            // are implementation assets rather than user files. Skip them for both
            // whole-Mac and user-selected-folder scans. The package itself is not
            // emitted as a regular file, so it does not pollute the result list.
            if values?.isPackage == true || PathRules.isPackage(item) {
                enumerator.skipDescendants()
                continue
            }

            guard values?.isRegularFile == true, values?.isReadable != false else {
                continue
            }

            let size = Int64(values?.fileSize ?? 0)
            let category = TypeDetector.category(for: item)
            guard enabled.contains(category) else { continue }

            let walked = WalkedFile(
                url: item,
                size: size,
                created: values?.creationDate,
                modified: values?.contentModificationDate,
                uti: values?.typeIdentifier
            )
            onFile(walked)
        }
    }

    private func volumeID(of url: URL) -> (NSCopying & NSSecureCoding & NSObjectProtocol)? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }

    private static func sameVolume(
        _ a: NSCopying & NSSecureCoding & NSObjectProtocol,
        _ b: NSCopying & NSSecureCoding & NSObjectProtocol
    ) -> Bool {
        guard let ao = a as? NSObject, let bo = b as? NSObject else { return false }
        return ao.isEqual(bo)
    }

    static func mountedVolumes() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
    }
}
