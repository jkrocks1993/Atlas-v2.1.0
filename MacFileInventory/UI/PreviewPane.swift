import SwiftUI
import AVKit
import AVFoundation
import PDFKit
import AppKit
import QuickLookUI

struct PreviewPane: View {
    @EnvironmentObject private var state: AppState
    @State private var zoom: Double = 1.0
    @State private var zoomAnchor: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Preview")
                Spacer()
                Text(String(format: "%.0f%%", zoom * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textDim)
                Button("Fit") { zoom = 1.0 }
                    .buttonStyle(MatteButtonStyle(kind: .quiet))
            }
            if let rec = state.selectedFile {
                previewBody(rec)
                    .id(rec.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let next = (zoomAnchor == 0 ? 1.0 : zoomAnchor) * value
                                zoom = min(8, max(0.25, next))
                            }
                            .onEnded { _ in
                                zoomAnchor = zoom
                            }
                    )
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.textDim)
                    Text("Select a file to preview")
                        .foregroundColor(Theme.textDim)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .background(Theme.paper)
        .onChange(of: state.selectedFileID) { _ in
            zoom = 1.0
            zoomAnchor = 1.0
        }
    }

    @ViewBuilder
    private func previewBody(_ rec: FileRecord) -> some View {
        switch rec.category {
        case .images:
            if rec.ext == "pdf" {
                PDFPreviewHost(url: rec.url, zoom: zoom)
                    .id(rec.url.path)
            } else {
                ImagePreview(url: rec.url, zoom: zoom)
            }
        case .videos, .audio:
            VideoPreviewHost(url: rec.url)
                .id(rec.url.path)
        case .pdfs:
            if ["epub", "doc", "docx", "rtf", "pages"].contains(rec.ext) {
                GenericQLPreview(url: rec.url)
                    .id(rec.url.path)
            } else {
                PDFPreviewHost(url: rec.url, zoom: zoom)
                    .id(rec.url.path)
            }
        default:
            GenericQLPreview(url: rec.url)
                .id(rec.url.path)
        }
    }
}

struct ImagePreview: View {
    let url: URL
    var zoom: Double

    var body: some View {
        GeometryReader { geo in
            if let image = NSImage(contentsOf: url) {
                let fitted = fit(image.size, in: geo.size)
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                }
            } else {
                Text("Unable to load image")
                    .foregroundColor(Theme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

struct VideoPreviewHost: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let current = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        if current != url {
            nsView.player?.pause()
            nsView.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

struct PDFPreviewHost: NSViewRepresentable {
    let url: URL
    var zoom: Double

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
            nsView.autoScales = true
        }
        if abs(zoom - 1.0) < 0.02 {
            nsView.autoScales = true
        } else {
            nsView.autoScales = false
            nsView.scaleFactor = zoom
        }
    }
}

struct GenericQLPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        if let view = QLPreviewView(frame: .zero, style: .normal) {
            view.autostarts = true
            view.previewItem = url as NSURL
            return view
        }
        let fallback = NSTextField(labelWithString: url.path)
        fallback.maximumNumberOfLines = 8
        return fallback
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? QLPreviewView {
            view.previewItem = url as NSURL
        }
    }
}
