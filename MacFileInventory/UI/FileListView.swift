import SwiftUI
import AppKit
import ImageIO
import CoreGraphics
import QuickLookThumbnailing
import AVFoundation

struct FileListView: View {
    @EnvironmentObject private var state: AppState
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var dragRect: CGRect?
    @State private var dragBase: Set<UUID> = []
    @State private var dragArmed = false

    var body: some View {
        let rows = state.displayedRows()
        ScrollViewReader { proxy in
            ZStack(alignment: .topLeading) {
                ArrowKeyHost(
                    onUp: { move(-1, proxy: proxy) },
                    onDown: { move(1, proxy: proxy) }
                )
                .frame(width: 1, height: 1)
                ScrollView {
                    Group {
                        if state.resultLayout == .list {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(rows) { row in
                                    if let fileID = row.fileID {
                                        rowView(row)
                                            .id(fileID)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 5)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(ItemFrameReader(id: fileID))
                                            .overlay(alignment: .leading) {
                                                if state.selectedFileID == fileID {
                                                    RoundedRectangle(cornerRadius: 2)
                                                        .fill(Theme.copper)
                                                        .frame(width: 3)
                                                        .padding(.vertical, 6)
                                                }
                                            }
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(state.checkedIDs.contains(fileID) || state.selectedFileID == fileID ? Theme.selection : Theme.raised)
                                            )
                                    } else {
                                        rowView(row)
                                    }
                                }
                            }
                            .padding(8)
                        } else {
                            TileBoard(rows: rows, side: state.resultLayout.tile)
                                .padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .coordinateSpace(name: "atlasList")
                    .onPreferenceChange(ItemFrameKey.self) { itemFrames = $0 }
                    .overlay(alignment: .topLeading) {
                        if let dragRect, dragRect.width > 3 || dragRect.height > 3 {
                            Rectangle()
                                .fill(Theme.matteBlue.opacity(0.16))
                                .overlay(Rectangle().stroke(Theme.matteBlue, lineWidth: 1))
                                .frame(width: max(dragRect.width, 1), height: max(dragRect.height, 1))
                                .offset(x: dragRect.minX, y: dragRect.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(dragSelect)
                }
                .background(Theme.inkSoft)
            }
            .onMoveCommand { direction in
                switch direction {
                case .up: move(-1, proxy: proxy)
                case .down: move(1, proxy: proxy)
                default: break
                }
            }
            .onAppear {
                if state.phase == .completed && rows.isEmpty { state.reloadRows() }
                jumpToTop(rows: rows, proxy: proxy)
            }
            .onChange(of: state.rowResetGeneration) { _ in
                jumpToTop(rows: state.displayedRows(), proxy: proxy)
            }
            .onChange(of: state.activeCategory) { _ in
                state.reloadRows(preserveVisible: false)
            }
            .onChange(of: state.activeSubtab) { _ in
                state.reloadRows(preserveVisible: false)
            }
            .onChange(of: state.activeKind) { _ in
                state.reloadRows(preserveVisible: false)
            }
            .onChange(of: state.searchText) { _ in state.scheduleSearchReload() }
            .onChange(of: state.sortField) { _ in state.reloadRows(preserveVisible: false) }
            .onChange(of: state.sortDirection) { _ in state.reloadRows(preserveVisible: false) }
        }
    }

    private func jumpToTop(rows: [ListRow], proxy: ScrollViewProxy) {
        let ids = rows.compactMap(\.fileID)
        guard let first = ids.first else { return }
        // Preserve the current selection when the result store refreshes. This prevents
        // tab/search refreshes from visibly jumping to a different file.
        if state.selectedFileID == nil || !ids.contains(state.selectedFileID!) {
            state.selectForPreview(first)
            DispatchQueue.main.async {
                proxy.scrollTo(first, anchor: UnitPoint.top)
            }
        }
    }

    private func move(_ delta: Int, proxy: ScrollViewProxy) {
        let ids = state.displayedRows().compactMap(\.fileID)
        guard !ids.isEmpty else { return }
        let current = state.selectedFileID.flatMap { ids.firstIndex(of: $0) } ?? -1
        var next = current + delta
        if current < 0 { next = delta > 0 ? 0 : ids.count - 1 }
        next = max(0, min(ids.count - 1, next))
        let id = ids[next]
        state.selectForPreview(id)
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: nil) }
    }

    private var dragSelect: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("atlasList"))
            .onChanged { value in
                if !dragArmed {
                    dragArmed = true
                    dragBase = state.checkedIDs
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                dragRect = rect
                let hits = Set(itemFrames.compactMap { id, frame in frame.intersects(rect) ? id : nil })
                let command = NSEvent.modifierFlags.contains(.command)
                state.applyDragSelection(hits, command: command, base: dragBase)
            }
            .onEnded { _ in
                dragArmed = false
                dragRect = nil
            }
    }

    @ViewBuilder
    private func rowView(_ row: ListRow) -> some View {
        switch row {
        case .separator:
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 3)
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                .listRowSeparator(.hidden)
        case .unique(let fileID), .best(_, let fileID), .member(_, let fileID):
            if let display = state.displayRecord(for: fileID) {
                FileRow(display: display)
            }
        }
    }
}

struct FileRow: View {
    @EnvironmentObject private var state: AppState
    let display: ListDisplayRecord

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { state.checkedIDs.contains(display.id) },
                set: { on in
                    if on { state.checkedIDs.insert(display.id) } else { state.checkedIDs.remove(display.id) }
                    state.selectForPreview(display.id)
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Button {
                state.handlePointerSelection(display.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: display.isBest ? "star.fill" : "star")
                        .foregroundColor(display.isBest ? Theme.bestGold : .clear)
                        .help(display.isBest ? "BEST / original — not protected from deletion" : "")

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            if display.isBest {
                                Text("BEST")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.bestGold.opacity(0.2)))
                                    .foregroundColor(Theme.bestGold)
                            }
                            Text(display.name)
                                .font(.system(size: 12.5, weight: display.isBest ? .semibold : .regular))
                                .foregroundColor(Theme.text)
                                .lineLimit(1)
                        }
                        Text("\(display.path)  ·  \(ByteFormat.string(display.size))  ·  \(DateFormat.string(display.modified))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, display.indented ? 22 : 0)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct ResultBand: Identifiable {
    let id: String
    let files: [ListRow]
}

struct TileBoard: View {
    @EnvironmentObject private var state: AppState
    let rows: [ListRow]
    let side: CGFloat

    private var bands: [ResultBand] {
        var out: [ResultBand] = []
        var current: [ListRow] = []
        func flush() {
            guard !current.isEmpty else { return }
            out.append(ResultBand(id: "band-\(out.count)-\(current.first?.id ?? "")", files: current))
            current = []
        }
        for row in rows {
            if case .separator = row {
                flush()
            } else if row.fileID != nil {
                current.append(row)
            }
        }
        flush()
        return out
    }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: side, maximum: side + 36), spacing: 10)]
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(band.files) { row in
                        if let fileID = row.fileID, let display = state.displayRecord(for: fileID) {
                            FileTile(display: display, side: side, isBest: {
                                if case .best = row { return true }
                                return display.isBest
                            }())
                            .background(ItemFrameReader(id: fileID))
                            .id(fileID)
                        }
                    }
                }
                .padding(.vertical, 8)
                if index < bands.count - 1 {
                    Rectangle()
                        .fill(Theme.copper.opacity(0.85))
                        .frame(height: 6)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Duplicate group separator")
                }
            }
        }
    }
}

struct FileTile: View {
    @EnvironmentObject private var state: AppState
    let display: ListDisplayRecord
    let side: CGFloat
    let isBest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                TileThumb(path: display.path)
                    .frame(width: side - 16, height: (side - 16) * 0.78)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if isBest {
                    Text("BEST")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.bestGold))
                        .foregroundColor(Theme.ink)
                        .padding(6)
                }
            }
            Text(display.name)
                .font(.system(size: 11, weight: isBest ? .semibold : .regular))
                .foregroundColor(Theme.text)
                .lineLimit(2)
            Text(ByteFormat.string(display.size))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(width: side, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(state.checkedIDs.contains(display.id) || state.selectedFileID == display.id ? Theme.selection : Theme.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(state.selectedFileID == display.id ? Theme.matteBlue : (state.checkedIDs.contains(display.id) ? Theme.matteBlue.opacity(0.7) : Color.white.opacity(0.06)), lineWidth: state.selectedFileID == display.id || state.checkedIDs.contains(display.id) ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { state.handlePointerSelection(display.id) }
        .overlay(alignment: .topLeading) {
            Toggle("", isOn: Binding(
                get: { state.checkedIDs.contains(display.id) },
                set: { on in
                    if on { state.checkedIDs.insert(display.id) } else { state.checkedIDs.remove(display.id) }
                    state.selectForPreview(display.id)
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .padding(10)
        }
    }
}

struct TileThumb: View {
    let path: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Theme.inkSoft
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else if failed {
                Image(systemName: "doc")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.muted)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: path) {
            let loaded = await ThumbCache.shared.image(path: path, maxPixel: 360)
            image = loaded
            failed = loaded == nil
        }
    }
}

final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    private static let slots = DispatchSemaphore(value: 4)
    private init() { cache.countLimit = 1200 }

    func image(path: String, maxPixel: CGFloat) async -> NSImage? {
        let key = "\(Int(maxPixel))|\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let cg: CGImage? = await Task.detached(priority: .utility) {
            ThumbCache.slots.wait()
            defer { ThumbCache.slots.signal() }
            return ThumbCache.cgImage(path: path, maxPixel: maxPixel)
        }.value
        let image: NSImage?
        if let cg {
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            image = await MainActor.run { NSWorkspace.shared.icon(forFile: path) }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func cgImage(path: String, maxPixel: CGFloat) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let stills: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "jp2", "pdf", "psd"]
        if stills.contains(ext), let still = imageIO(url, maxPixel: maxPixel) { return still }
        let video: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "mpg", "mpeg", "wmv", "flv", "webm", "3gp"]
        if video.contains(ext), let frame = videoFrame(url, maxPixel: maxPixel) { return frame }
        return quickLook(url, maxPixel: maxPixel)
    }

    private static func quickLook(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 2,
            representationTypes: .thumbnail
        )
        let gate = DispatchSemaphore(value: 0)
        var image: CGImage?
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            image = rep?.cgImage
            gate.signal()
        }
        _ = gate.wait(timeout: .now() + 2.5)
        return image
    }

    private static func imageIO(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func videoFrame(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let time = CMTime(seconds: 0.4, preferredTimescale: 600)
        return try? generator.copyCGImage(at: time, actualTime: nil)
    }
}

private struct ItemFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct ItemFrameReader: View {
    let id: UUID
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ItemFrameKey.self, value: [id: geo.frame(in: .named("atlasList"))])
        }
    }
}

/// Invisible first-responder that always receives arrow keys on macOS 13.
struct ArrowKeyHost: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUp: onUp, onDown: onDown)
    }

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.coordinator = context.coordinator
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUp = onUp
        context.coordinator.onDown = onDown
        if let view = nsView as? KeyView {
            view.coordinator = context.coordinator
        }
    }

    final class Coordinator {
        var onUp: () -> Void
        var onDown: () -> Void
        init(onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
            self.onUp = onUp
            self.onDown = onDown
        }
    }

    final class KeyView: NSView {
        var coordinator: Coordinator?
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    if self.isEditingText { return event }
                    switch event.keyCode {
                    case 126:
                        self.coordinator?.onUp()
                        return nil
                    case 125:
                        self.coordinator?.onDown()
                        return nil
                    default:
                        return event
                    }
                }
            }
        }
        override func removeFromSuperview() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            super.removeFromSuperview()
        }
        private var isEditingText: Bool {
            guard let responder = window?.firstResponder else { return false }
            return responder is NSTextView || responder is NSTextField || responder is NSText
        }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: coordinator?.onUp()
            case 125: coordinator?.onDown()
            default: super.keyDown(with: event)
            }
        }
    }
}
