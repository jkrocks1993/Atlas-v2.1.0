# Source-level review

Reviewed before packaging. This environment cannot run `xcodebuild` (Linux sandbox, no Xcode). Review is static.

## Project completeness

- 27 Swift files, all listed in `project.pbxproj` Sources
- Shared scheme `MacFileInventory`
- Info.plist + entitlements (App Sandbox OFF so Entire Mac / FDA can work)
- Assets catalog present
- `build.sh` is executable
- Deployment target 13.0, `ARCHS = x86_64`

## Types and methods

Referenced types exist: FileCategory, FileRecord, DuplicateGroup, ScanLocation, ScanPhase, ScanStatistics, ListRow, AppState, ScanEngine, ScanControl, DirectoryWalker, TypeDetector, DuplicateEngine, ImageAnalyzer, VideoAnalyzer, PDFAnalyzer, OfficeAnalyzer, ArchiveAnalyzer, ZipReader, FileOperations, EnhanceEngine, EnhancementRequest, MoveSummaryCategory.

UI entry: `MacFileInventoryApp` → `ContentView` → ControlPanel, ResultTabs, ResultsPane, FileListView, PreviewPane, MoveConfirmSheet, EnhanceSheet.

File operations: `deleteChecked()` (Trash via `FileManager.trashItem`), `requestMove()` / `confirmMove()` (collision-safe `moveItem`).

## Imports / frameworks

SwiftUI, AppKit, AVFoundation, AVKit, PDFKit, QuickLookUI, CryptoKit, ImageIO, CoreImage, CoreML, UniformTypeIdentifiers, Combine, Compression, CoreGraphics.

ZIP inflate uses Compression.framework, not libz Swift bindings.

## Duplicate detection

- Filename is never a grouping key
- Exact SHA-256 first
- Images: DCT pHash + dHash + 16×16 grid + aspect; Hamming ≤ 3 and MAD ≤ 6
- Videos: 7 frame samples, ≥ 6 frames Hamming ≤ 4 plus duration tolerance
- PDFs: text hash or page hashes; image-only PDFs can join image groups
- Office: OOXML XML extract
- ZIP: central-directory manifest
- RAR: RAR4 only; otherwise Uncompared
- Failed decode → Uncompared

## UI / state

- Custom tab bars with fixed height; disabled categories do not resize the window
- Real checkbox `Toggle` + `.checkbox`
- Row tap selects preview only
- `List(selection:)` + `onMoveCommand` + `ScrollViewReader`
- VideoPlayer kept
- Large green progress bar + single-line statistics
- Second scan keeps previous results until the first replacement file arrives
- BEST is not protected; promotion alert after delete/move

## Known compiler notes (not errors)

- `AVAsset.tracks(withMediaType:)` and `copyCGImage` are older AVFoundation APIs; valid on macOS 13, may warn on newer SDKs
- `FileHandle.offsetInFile` / `seek(toFileOffset:)` same
- No bundled `.mlmodel`; enhancement UI states that Core Image is used instead of calling resize “AI”
- App icon slots are empty placeholders; the app still builds
- Automatic signing needs a local team or ad-hoc (`CODE_SIGN_IDENTITY="-"` in `build.sh`)

## Intentionally absent (per spec)

- Filter button
- Uncompared as a scan checkbox
- Filename duplicate matching
- Permanent delete
- Protected BEST
- Cloud / telemetry
