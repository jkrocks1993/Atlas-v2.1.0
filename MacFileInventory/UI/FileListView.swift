import SwiftUI
import AppKit
import ImageIO
import CoreGraphics
import QuickLookThumbnailing
import AVFoundation

struct FileListView: View {
    @EnvironmentObject private var state: AppState
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var viewport: CGSize = CGSize(width: 640, height: 480)
    @State private var lastNavStamp: TimeInterval = 0
    @State private var lastNavKey: String = ""
    @State private var scrollRequest = ScrollRequest()

    var body: some View {
        let rows = state.displayedRows()
        ZStack(alignment: .topLeading) {
            ArrowKeyHost(
                onUp: { move(dx: 0, dy: -1) },
                onDown: { move(dx: 0, dy: 1) },
                onLeft: { move(dx: -1, dy: 0) },
                onRight: { move(dx: 1, dy: 0) }
            )
            .frame(width: 1, height: 1)
            ScrollView {
                    ZStack(alignment: .topLeading) {
                        ScrollDriver(request: scrollRequest, frames: itemFrames)
                            .frame(width: 1, height: 1)
                            .allowsHitTesting(false)
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
                                                .background(RowAnchor(id: fileID))
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
                        DragCatcher(
                            frames: itemFrames,
                            checked: state.checkedIDs,
                            onSelection: { hits, command, base in
                                state.applyDragSelection(hits, command: command, base: base)
                            },
                            onFinish: {
                                if let id = state.checkedIDs.first { state.selectForPreview(id) }
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, minHeight: viewport.height, alignment: .topLeading)
                    .coordinateSpace(name: "atlasList")
                    .onPreferenceChange(ItemFrameKey.self) { frames in
                        let changed = frames.count != itemFrames.count || frames.contains { id, frame in
                            guard let old = itemFrames[id] else { return true }
                            return abs(old.minX - frame.minX) > 1 || abs(old.minY - frame.minY) > 1
                        }
                        if changed { itemFrames = frames }
                    }
                }
                .scrollIndicators(.visible)
                .background(Theme.inkSoft)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { viewport = geo.size }
                            .onChange(of: geo.size) { viewport = $0 }
                    }
                )
            }
            .onMoveCommand { direction in
                switch direction {
                case .up: move(dx: 0, dy: -1)
                case .down: move(dx: 0, dy: 1)
                case .left: move(dx: -1, dy: 0)
                case .right: move(dx: 1, dy: 0)
                default: break
                }
            }
            .onAppear {
                if state.phase == .completed && rows.isEmpty { state.reloadRows() }
                jumpToTop(rows: rows)
            }
            .onChange(of: state.rowResetGeneration) { _ in
                jumpToTop(rows: state.displayedRows())
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

    private func jumpToTop(rows: [ListRow]) {
        let ids = rows.compactMap(\.fileID)
        guard let first = ids.first else { return }
        // Preserve the current selection when the result store refreshes. This prevents
        // tab/search refreshes from visibly jumping to a different file.
        if state.selectedFileID == nil || !ids.contains(state.selectedFileID!) {
            state.selectForPreview(first)
            DispatchQueue.main.async {
                self.pinListToTop()
            }
        }
    }

    private func move(dx: Int, dy: Int) {
        let key = "\(dx),\(dy)"
        let now = ProcessInfo.processInfo.systemUptime
        if key == lastNavKey && now - lastNavStamp < 0.02 { return }
        lastNavStamp = now
        lastNavKey = key
        let bands = tileBands()
        let flat = bands.flatMap { $0 }
        guard !flat.isEmpty else { return }
        if state.resultLayout == .list || (dx == 0 && dy == 0) {
            let step = dy != 0 ? dy : dx
            stepLinear(step, ids: flat)
            return
        }
        let cols = tileColumns()
        guard let current = state.selectedFileID, let place = locate(current, in: bands) else {
            preview(flat[0], direction: dy != 0 ? dy : dx)
            return
        }
        let band = bands[place.band]
        let col = place.index % cols
        let row = place.index / cols
        if dx != 0 {
            let nextCol = col + dx
            let sameRow = row * cols + nextCol
            if nextCol >= 0 && nextCol < cols && sameRow < band.count {
                preview(band[sameRow], direction: 0)
                return
            }
            if dx > 0, place.band + 1 < bands.count {
                preview(bands[place.band + 1][0], direction: 1)
            } else if dx < 0, place.band > 0 {
                preview(bands[place.band - 1].last!, direction: -1)
            }
            return
        }
        let nextRow = row + dy
        let rowsInBand = max(1, (band.count + cols - 1) / cols)
        if nextRow >= 0 && nextRow < rowsInBand && nextRow * cols < band.count {
            preview(band[min(nextRow * cols + col, band.count - 1)], direction: dy)
            return
        }
        if dy > 0, place.band + 1 < bands.count {
            let next = bands[place.band + 1]
            preview(next[min(col, next.count - 1)], direction: 1)
        } else if dy < 0, place.band > 0 {
            let prev = bands[place.band - 1]
            let prevRows = max(1, (prev.count + cols - 1) / cols)
            let idx = min((prevRows - 1) * cols + col, prev.count - 1)
            preview(prev[max(0, idx)], direction: -1)
        }
    }

    private func stepLinear(_ delta: Int, ids: [UUID]) {
        let current = state.selectedFileID.flatMap { ids.firstIndex(of: $0) } ?? -1
        var next = current + delta
        if current < 0 { next = delta > 0 ? 0 : ids.count - 1 }
        next = max(0, min(ids.count - 1, next))
        preview(ids[next], direction: delta)
    }

    /// Arrow keys already change the preview. The list moves only when that
    /// file would leave the window: down parks it on the bottom edge, up on the top.
    private func preview(_ id: UUID, direction: Int) {
        guard state.selectedFileID != id else { return }
        state.selectForPreview(id)
        var request = ScrollRequest()
        request.token = scrollRequest.token + 1
        request.fileID = id
        request.direction = direction == 0 ? 0 : (direction > 0 ? 1 : -1)
        request.fallbackHeight = rowEstimate
        if let frame = itemFrames[id], frame.height > 4, frame.height < 2000 {
            request.hasFrame = true
            request.frame = frame
        }
        scrollRequest = request
    }

    private func pinListToTop() {
        var request = scrollRequest
        request.token += 1
        request.pinToTop = true
        scrollRequest = request
    }

    private var rowEstimate: CGFloat {
        if let measured = RowAnchors.typicalHeight() { return measured }
        if state.resultLayout != .list {
            return min(320, state.resultLayout.tile + 28)
        }
        return 46
    }

    private func tileBands() -> [[UUID]] {
        var bands: [[UUID]] = []
        var current: [UUID] = []
        for row in state.displayedRows() {
            if case .separator = row {
                if !current.isEmpty { bands.append(current); current = [] }
            } else if let id = row.fileID {
                current.append(id)
            }
        }
        if !current.isEmpty { bands.append(current) }
        return bands
    }

    private func tileColumns() -> Int {
        let side = state.resultLayout.tile
        guard side > 0 else { return 1 }
        let width = max(side, viewport.width - 20)
        return max(1, Int(floor((width + 10) / (side + 10))))
    }

    private func locate(_ id: UUID, in bands: [[UUID]]) -> (band: Int, index: Int)? {
        for (band, files) in bands.enumerated() {
            if let index = files.firstIndex(of: id) { return (band, index) }
        }
        return nil
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
    @State private var hovering = false

    var body: some View {
        let checked = state.checkedIDs.contains(display.id)
        let current = state.selectedFileID == display.id
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { checked },
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
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.bestGold.opacity(0.22)))
                                    .foregroundColor(Theme.bestGold)
                            }
                            Text(display.name)
                                .font(.system(size: 12.5, weight: display.isBest ? .semibold : .regular, design: .rounded))
                                .foregroundColor(Theme.text)
                                .lineLimit(1)
                        }
                        Text("\(display.path)  ·  \(ByteFormat.string(display.size))  ·  \(DateFormat.string(display.modified))")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(Theme.textDim)
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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering && !current && !checked ? Color.white.opacity(0.05) : Color.clear)
        )
        .onHover { hovering = $0 }
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
                            .background(RowAnchor(id: fileID))
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
    @State private var hovering = false

    var body: some View {
        let checked = state.checkedIDs.contains(display.id)
        let current = state.selectedFileID == display.id
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                TileThumb(path: display.path)
                    .frame(width: side - 16, height: (side - 16) * 0.78)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if isBest {
                    Text("BEST")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.bestGold))
                        .foregroundColor(Theme.ink)
                        .padding(6)
                }
            }
            Text(display.name)
                .font(.system(size: 11, weight: isBest ? .semibold : .regular, design: .rounded))
                .foregroundColor(Theme.text)
                .lineLimit(2)
            Text(ByteFormat.string(display.size))
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(Theme.textDim)
                .lineLimit(1)
        }
        .padding(8)
        .frame(width: side, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(current || checked ? Theme.selection : (hovering ? Theme.raised2 : Theme.raised))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(current ? Theme.matteBlue : (checked ? Theme.matteBlue.opacity(0.7) : Color.white.opacity(hovering ? 0.16 : 0.06)), lineWidth: current || checked ? 2 : 1)
        )
        .shadow(color: current ? Theme.matteBlue.opacity(0.35) : Color.black.opacity(0.18), radius: current ? 10 : 4, y: 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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

private struct ScrollRequest: Equatable {
    var token = 0
    var pinToTop = false
    var fileID: UUID?
    var direction = 0
    var fallbackHeight: CGFloat = 46
    var hasFrame = false
    var frame = CGRect.zero
}

/// Scrolls the real AppKit list so the highlighted file stays inside the window.
/// SwiftUI frames are not used as document coordinates — those were landing the
/// highlight outside the visible clip. Each row has an anchor view, and the clip
/// is moved by the measured overflow only.
private struct ScrollDriver: NSViewRepresentable {
    var request: ScrollRequest
    var frames: [UUID: CGRect]

    func makeNSView(context: Context) -> ScrollDriverView {
        let view = ScrollDriverView()
        view.request = request
        view.frames = frames
        return view
    }

    func updateNSView(_ view: ScrollDriverView, context: Context) {
        let changed = view.request.token != request.token
        view.request = request
        view.frames = frames
        if changed { view.reveal() }
    }
}

private final class ScrollDriverView: NSView {
    var request = ScrollRequest()
    var frames: [UUID: CGRect] = [:]
    override var isFlipped: Bool { true }

    func reveal() {
        let request = self.request
        DispatchQueue.main.async { [weak self] in
            guard let self, self.request.token == request.token else { return }
            self.revealNow(request, attempt: 0, previousOverflow: nil)
        }
    }

    private func revealNow(_ request: ScrollRequest, attempt: Int, previousOverflow: CGFloat?) {
        guard request.token == self.request.token else { return }
        guard let scroll = enclosingScrollView else {
            retry(request, attempt: attempt, previousOverflow: previousOverflow)
            return
        }
        let clip = scroll.contentView
        if request.pinToTop {
            var origin = clip.bounds.origin
            if clip.isFlipped {
                origin.y = 0
            } else {
                let docH = scroll.documentView?.bounds.height ?? clip.bounds.height
                origin.y = max(0, docH - clip.bounds.height)
            }
            origin.x = 0
            apply(origin, clip: clip, scroll: scroll)
            return
        }
        guard let id = request.fileID else { return }
        if let item = itemWindowRect(id, request: request), item.height > 4, item.width > 4 {
            let visible = clip.convert(clip.bounds, to: nil)
            guard visible.height > 4 else {
                retry(request, attempt: attempt, previousOverflow: previousOverflow)
                return
            }
            let below = visible.minY - item.minY
            let above = item.maxY - visible.maxY
            if below <= 1, above <= 1 { return }
            let overflow = max(below, above)
            if let previousOverflow, attempt > 0, abs(overflow - previousOverflow) < 2 {
                if attempt < 3 { retry(request, attempt: attempt, previousOverflow: overflow) }
                return
            }
            var origin = clip.bounds.origin
            if item.height >= visible.height - 8 {
                let delta = item.maxY - visible.maxY
                origin.y += clip.isFlipped ? -delta : delta
            } else if below > 1 {
                origin.y += clip.isFlipped ? below : -below
            } else if above > 1 {
                origin.y += clip.isFlipped ? -above : above
            } else {
                return
            }
            apply(origin, clip: clip, scroll: scroll)
            if attempt < 2 { retry(request, attempt: attempt, previousOverflow: overflow) }
            return
        }
        guard attempt < 8, request.direction != 0 else { return }
        nudge(request, in: scroll)
        retry(request, attempt: attempt, previousOverflow: previousOverflow)
    }

    /// The file's rectangle in window coordinates, where Y grows upward.
    /// The row anchor is measured directly. A SwiftUI frame is used only after it
    /// has been lined up against a row that is already on screen.
    private func itemWindowRect(_ id: UUID, request: ScrollRequest) -> CGRect? {
        if let anchor = RowAnchors.view(for: id), anchor.window != nil {
            let rect = anchor.convert(anchor.bounds, to: nil)
            if rect.height > 4, rect.width > 4 { return rect }
        }
        guard request.hasFrame, request.frame.height > 4, request.frame.height < 2000 else { return nil }
        for (otherID, other) in frames {
            guard other.height > 8, other.height < 800,
                  let anchor = RowAnchors.view(for: otherID), anchor.window != nil else { continue }
            let live = anchor.convert(anchor.bounds, to: nil)
            guard live.height > 4 else { continue }
            let scale = live.height / other.height
            guard scale > 0.5, scale < 2 else { continue }
            let delta = live.minY - other.minY * scale
            return CGRect(
                x: live.minX,
                y: request.frame.minY * scale + delta,
                width: max(1, request.frame.width),
                height: max(1, request.frame.height * scale)
            )
        }
        return nil
    }

    private func nudge(_ request: ScrollRequest, in scroll: NSScrollView) {
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        let step = min(max(request.fallbackHeight, 24), 220)
        let delta = step * CGFloat(request.direction > 0 ? 1 : -1)
        origin.y += clip.isFlipped ? delta : -delta
        apply(origin, clip: clip, scroll: scroll)
    }

    private func apply(_ origin: NSPoint, clip: NSClipView, scroll: NSScrollView) {
        var origin = origin
        let docH = scroll.documentView?.bounds.height ?? clip.bounds.height
        let limit = max(0, docH - clip.bounds.height)
        origin.y = min(max(0, origin.y), limit)
        origin.x = clip.bounds.origin.x
        if abs(origin.y - clip.bounds.origin.y) < 0.5 { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func retry(_ request: ScrollRequest, attempt: Int, previousOverflow: CGFloat?) {
        let next = attempt + 1
        guard next <= 8 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.request.token == request.token else { return }
            self.revealNow(request, attempt: next, previousOverflow: previousOverflow)
        }
    }
}

private final class RowAnchorBox {
    weak var view: RowAnchorView?
    init(_ view: RowAnchorView) { self.view = view }
}

private enum RowAnchors {
    static var boxes: [UUID: RowAnchorBox] = [:]

    static func register(_ view: RowAnchorView) {
        boxes[view.fileID] = RowAnchorBox(view)
    }

    static func unregister(_ view: RowAnchorView) {
        if boxes[view.fileID]?.view === view {
            boxes.removeValue(forKey: view.fileID)
        }
    }

    static func view(for id: UUID) -> RowAnchorView? {
        guard let view = boxes[id]?.view, view.window != nil, view.bounds.height > 1 else { return nil }
        return view
    }

    static func typicalHeight() -> CGFloat? {
        let heights = boxes.values.compactMap { $0.view?.bounds.height }.filter { $0 > 16 && $0 < 400 }
        guard !heights.isEmpty else { return nil }
        return heights.reduce(0, +) / CGFloat(heights.count)
    }
}

private struct RowAnchor: NSViewRepresentable {
    var id: UUID

    func makeNSView(context: Context) -> RowAnchorView {
        let view = RowAnchorView()
        view.fileID = id
        RowAnchors.register(view)
        return view
    }

    func updateNSView(_ view: RowAnchorView, context: Context) {
        if view.fileID != id {
            RowAnchors.unregister(view)
            view.fileID = id
        }
        RowAnchors.register(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RowAnchorView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 8, height: proposal.height ?? 8)
    }
}

private final class RowAnchorView: NSView {
    var fileID: UUID = UUID()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { RowAnchors.register(self) }
        else { RowAnchors.unregister(self) }
    }
    override func removeFromSuperview() {
        RowAnchors.unregister(self)
        super.removeFromSuperview()
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

/// Rubber-band selection that also covers the empty area under and beside the tiles.
/// The rectangle is drawn in AppKit so the file list is not rebuilt on every pointer move.
private struct DragCatcher: NSViewRepresentable {
    var frames: [UUID: CGRect]
    var checked: Set<UUID>
    var onSelection: (Set<UUID>, Bool, Set<UUID>) -> Void
    var onFinish: () -> Void

    func makeNSView(context: Context) -> DragCatcherView {
        let view = DragCatcherView()
        view.frames = frames
        view.checked = checked
        view.onSelection = onSelection
        view.onFinish = onFinish
        return view
    }

    func updateNSView(_ view: DragCatcherView, context: Context) {
        view.frames = frames
        view.checked = checked
        view.onSelection = onSelection
        view.onFinish = onFinish
    }
}

private final class DragCatcherView: NSView {
    var frames: [UUID: CGRect] = [:]
    var checked: Set<UUID> = []
    var onSelection: ((Set<UUID>, Bool, Set<UUID>) -> Void)?
    var onFinish: (() -> Void)?
    private var origin: CGPoint?
    private var base: Set<UUID> = []
    private var lastHits: Set<UUID> = []
    private var band: CGRect?
    private var monitor: Any?
    private var didDrag = false

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard monitor == nil, window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.removeFromSuperview()
    }

    private func handle(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            guard bounds.contains(point) else { origin = nil; return }
            origin = point
            base = checked
            lastHits = []
            didDrag = false
        case .leftMouseDragged:
            guard let origin else { return }
            let rect = CGRect(
                x: min(origin.x, point.x),
                y: min(origin.y, point.y),
                width: abs(point.x - origin.x),
                height: abs(point.y - origin.y)
            )
            guard rect.width > 4 || rect.height > 4 else { return }
            didDrag = true
            band = rect
            needsDisplay = true
            let hits = Set(frames.compactMap { id, frame in frame.intersects(rect) ? id : nil })
            if hits != lastHits {
                lastHits = hits
                onSelection?(hits, event.modifierFlags.contains(.command), base)
            }
        case .leftMouseUp:
            let finished = didDrag
            origin = nil
            band = nil
            didDrag = false
            needsDisplay = true
            if finished { onFinish?() }
        default:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let band else { return }
        NSColor.systemBlue.withAlphaComponent(0.18).setFill()
        band.fill()
        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: band)
        path.lineWidth = 1
        path.stroke()
    }
}

/// Invisible first-responder that always receives arrow keys on macOS 13.
struct ArrowKeyHost: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void
    var onLeft: () -> Void
    var onRight: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUp: onUp, onDown: onDown, onLeft: onLeft, onRight: onRight)
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
        context.coordinator.onLeft = onLeft
        context.coordinator.onRight = onRight
        if let view = nsView as? KeyView {
            view.coordinator = context.coordinator
        }
    }

    final class Coordinator {
        var onUp: () -> Void
        var onDown: () -> Void
        var onLeft: () -> Void
        var onRight: () -> Void
        private var lastKey: (code: UInt16, at: TimeInterval)?
        init(onUp: @escaping () -> Void, onDown: @escaping () -> Void, onLeft: @escaping () -> Void, onRight: @escaping () -> Void) {
            self.onUp = onUp
            self.onDown = onDown
            self.onLeft = onLeft
            self.onRight = onRight
        }

        func handle(keyCode: UInt16) -> Bool {
            let now = ProcessInfo.processInfo.systemUptime
            if let lastKey, lastKey.code == keyCode, now - lastKey.at < 0.03 { return true }
            lastKey = (keyCode, now)
            switch keyCode {
            case 126: onUp(); return true
            case 125: onDown(); return true
            case 123: onLeft(); return true
            case 124: onRight(); return true
            default: return false
            }
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
                    case 126, 125, 123, 124:
                        if self.coordinator?.handle(keyCode: event.keyCode) == true { return nil }
                        return event
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
            if coordinator?.handle(keyCode: event.keyCode) == true { return }
            super.keyDown(with: event)
        }
    }
}
