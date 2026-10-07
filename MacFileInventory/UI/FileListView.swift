import SwiftUI
import AppKit
import ImageIO
import CoreGraphics

struct FileListView: View {
    @EnvironmentObject private var state: AppState

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
                    if state.resultLayout == .list {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row in
                                if let fileID = row.fileID {
                                    rowView(row)
                                        .id(fileID)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .frame(maxWidth: .infinity, alignment: .leading)
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
                                                .fill(state.selectedFileID == fileID ? Theme.selection : Theme.raised)
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
                    if on {
                        state.checkedIDs.insert(display.id)
                    } else {
                        state.checkedIDs.remove(display.id)
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

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
            Spacer()
        }
        .padding(.leading, display.indented ? 22 : 0)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectForPreview(display.id)
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
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
            ZStack(alignment: .topLeading) {
                TileThumb(path: display.path, side: side - 16)
                    .frame(width: side - 16, height: side - 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Toggle("", isOn: Binding(
                    get: { state.checkedIDs.contains(display.id) },
                    set: { on in
                        if on { state.checkedIDs.insert(display.id) } else { state.checkedIDs.remove(display.id) }
                    }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(6)
                if isBest {
                    Text("BEST")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.bestGold))
                        .foregroundColor(Theme.ink)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .trailing)
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
                .fill(state.selectedFileID == display.id ? Theme.selection : Theme.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(state.selectedFileID == display.id ? Theme.matteBlue : Color.white.opacity(0.06), lineWidth: state.selectedFileID == display.id ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectForPreview(display.id)
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

struct TileThumb: View {
    let path: String
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.inkSoft
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 22))
                    .foregroundColor(Theme.muted)
            }
        }
        .frame(width: side, height: side * 0.72)
        .clipped()
        .task(id: path) {
            let loaded = await ThumbCache.shared.image(path: path, maxPixel: max(160, side * 2))
            image = loaded
        }
    }
}

final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 800 }

    func image(path: String, maxPixel: CGFloat) async -> NSImage? {
        let key = "\(Int(maxPixel))|\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let loaded: NSImage? = await Task.detached(priority: .utility) {
            ThumbCache.decode(path: path, maxPixel: maxPixel)
        }.value
        if let loaded { cache.setObject(loaded, forKey: key) }
        return loaded
    }

    private static func decode(path: String, maxPixel: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let imageExt: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "jp2"]
        if imageExt.contains(ext),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return NSWorkspace.shared.icon(forFile: path)
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
