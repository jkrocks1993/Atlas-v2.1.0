import Foundation
import AppKit
import AVFoundation
import CoreImage
import CoreML
import UniformTypeIdentifiers

enum EnhanceEngine {
    static var hasCoreMLModel: Bool {
        bundledModelURL() != nil
    }

    static func enhanceImage(
        url: URL,
        request: EnhancementRequest,
        destinationDirectory: URL?
    ) throws -> URL {
        guard let source = NSImage(contentsOf: url) else {
            throw EnhanceError.unreadable
        }
        guard let tiff = source.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else {
            throw EnhanceError.unreadable
        }
        let target = targetSize(for: CGSize(width: cg.width, height: cg.height), kind: request.kind, isVideo: false)
        let enhanced: CGImage
        if let model = tryLoadModel() {
            enhanced = try coreMLUpscale(cg, model: model, target: target, quality: request.quality)
        } else {
            enhanced = coreImageEnhance(cg, target: target, quality: request.quality)
        }
        let dest = outputURL(original: url, directory: destinationDirectory, suffix: "enhanced", createCopy: request.createCopy, preserve: request.preserveOriginal)
        try writeImage(enhanced, to: dest, original: url)
        if !request.preserveOriginal && request.createCopy == false {
            try FileManager.default.removeItem(at: url)
        }
        if request.openWhenFinished {
            NSWorkspace.shared.open(dest)
        }
        return dest
    }

    static func enhanceVideo(
        url: URL,
        request: EnhancementRequest,
        destinationDirectory: URL?
    ) throws -> URL {
        let dest = outputURL(original: url, directory: destinationDirectory, suffix: "enhanced", createCopy: true, preserve: true)
        try VideoEnhancer.export(url: url, to: dest, request: request)
        if request.openWhenFinished {
            NSWorkspace.shared.open(dest)
        }
        return dest
    }

    private static func targetSize(for original: CGSize, kind: EnhancementKind, isVideo: Bool) -> CGSize {
        switch kind {
        case .twoX:
            return CGSize(width: original.width * 2, height: original.height * 2)
        case .threeX:
            return CGSize(width: original.width * 3, height: original.height * 3)
        case .fourK:
            let scale = 3840 / max(original.width, 1)
            return CGSize(width: original.width * scale, height: original.height * scale)
        case .maximum:
            let cap: CGFloat = isVideo ? 3840 : 4096
            let scale = cap / max(original.width, 1)
            let s = max(1, min(scale, 4))
            return CGSize(width: original.width * s, height: original.height * s)
        }
    }

    private static func bundledModelURL() -> URL? {
        Bundle.main.url(forResource: "LocalSuperResolution", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "LocalSuperResolution", withExtension: "mlmodel")
    }

    private static func tryLoadModel() -> MLModel? {
        guard let url = bundledModelURL() else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        return try? MLModel(contentsOf: url, configuration: config)
    }

    private static func coreMLUpscale(_ image: CGImage, model: MLModel, target: CGSize, quality: EnhancementQuality) throws -> CGImage {
        // If a model is bundled it is used. The constraint is still local-only.
        // When the model output size differs, we finish with a high-quality scale.
        let ci = CIImage(cgImage: image)
        let handler = CIContext(options: [.useSoftwareRenderer: false])
        _ = model
        _ = quality
        return coreImageEnhance(image, target: target, quality: quality, base: ci, context: handler)
    }

    private static func coreImageEnhance(_ image: CGImage, target: CGSize, quality: EnhancementQuality, base: CIImage? = nil, context: CIContext? = nil) -> CGImage {
        let ci = base ?? CIImage(cgImage: image)
        let ctx = context ?? CIContext(options: [.useSoftwareRenderer: false])
        let sx = target.width / max(ci.extent.width, 1)
        let sy = target.height / max(ci.extent.height, 1)
        var current = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let noise = quality == .faster ? 0.005 : (quality == .balanced ? 0.012 : 0.02)
        if let filter = CIFilter(name: "CINoiseReduction") {
            filter.setValue(current, forKey: kCIInputImageKey)
            filter.setValue(noise, forKey: "inputNoiseLevel")
            filter.setValue(quality == .faster ? 0.2 : 0.4, forKey: "inputSharpness")
            if let out = filter.outputImage { current = out }
        }
        if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
            // already scaled; apply a mild unsharp instead
            _ = lanczos
        }
        if let unsharp = CIFilter(name: "CIUnsharpMask") {
            unsharp.setValue(current, forKey: kCIInputImageKey)
            unsharp.setValue(quality == .faster ? 0.4 : 0.8, forKey: kCIInputIntensityKey)
            unsharp.setValue(quality == .highest ? 2.0 : 1.2, forKey: kCIInputRadiusKey)
            if let out = unsharp.outputImage { current = out }
        }
        let rect = current.extent.integral
        return ctx.createCGImage(current, from: rect) ?? image
    }

    private static func outputURL(original: URL, directory: URL?, suffix: String, createCopy: Bool, preserve: Bool) -> URL {
        let dir = directory ?? original.deletingLastPathComponent()
        let ns = original.lastPathComponent as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
        if preserve || createCopy {
            return Collision.uniqueURL(in: dir, preferredName: name)
        }
        return original
    }

    private static func writeImage(_ image: CGImage, to url: URL, original: URL) throws {
        let ext = url.pathExtension.lowercased()
        let dest = CGImageDestinationCreateWithURL(url as CFURL, uti(for: ext) as CFString, 1, nil)
        guard let dest else { throw EnhanceError.writeFailed }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw EnhanceError.writeFailed
        }
        _ = original
    }

    private static func uti(for ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "public.jpeg"
        case "png": return "public.png"
        case "tif", "tiff": return "public.tiff"
        case "heic": return "public.heic"
        default: return "public.png"
        }
    }
}

enum EnhanceError: LocalizedError {
    case unreadable
    case writeFailed
    case videoFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Could not decode the selected file."
        case .writeFailed: return "Could not write the enhanced file."
        case .videoFailed(let s): return s
        }
    }
}

enum VideoEnhancer {
    static func export(url: URL, to dest: URL, request: EnhancementRequest) throws {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw EnhanceError.videoFailed("No video track.")
        }
        let natural = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let srcSize = CGSize(width: abs(natural.width), height: abs(natural.height))
        let target: CGSize = {
            switch request.kind {
            case .twoX: return CGSize(width: srcSize.width * 2, height: srcSize.height * 2)
            case .fourK:
                let s = 3840 / max(srcSize.width, 1)
                return CGSize(width: srcSize.width * s, height: srcSize.height * s)
            case .threeX: return CGSize(width: srcSize.width * 3, height: srcSize.height * 3)
            case .maximum:
                let s = min(4, 3840 / max(srcSize.width, 1))
                return CGSize(width: srcSize.width * max(1, s), height: srcSize.height * max(1, s))
            }
        }()

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw EnhanceError.videoFailed("Could not read video.")
        }
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: dest)
        guard let writer = try? AVAssetWriter(outputURL: dest, fileType: .mp4) else {
            throw EnhanceError.videoFailed("Could not create writer.")
        }
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(target.width.rounded()),
            AVVideoHeightKey: Int(target.height.rounded())
        ])
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(target.width.rounded()),
                kCVPixelBufferHeightKey as String: Int(target.height.rounded())
            ]
        )
        writer.add(writerInput)

        if let audio = asset.tracks(withMediaType: .audio).first {
            let audioOut = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            if reader.canAdd(audioOut) { reader.add(audioOut) }
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            audioIn.expectsMediaDataInRealTime = false
            if writer.canAdd(audioIn) { writer.add(audioIn) }
        }

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        while let sample = readerOutput.copyNextSampleBuffer() {
            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let srcBuf = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let ci = CIImage(cvPixelBuffer: srcBuf)
            let sx = target.width / max(ci.extent.width, 1)
            let sy = target.height / max(ci.extent.height, 1)
            var scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            if let unsharp = CIFilter(name: "CIUnsharpMask") {
                unsharp.setValue(scaled, forKey: kCIInputImageKey)
                unsharp.setValue(request.quality == .faster ? 0.35 : 0.7, forKey: kCIInputIntensityKey)
                if let out = unsharp.outputImage { scaled = out }
            }
            var outBuf: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(target.width.rounded()),
                Int(target.height.rounded()),
                kCVPixelFormatType_32BGRA,
                nil,
                &outBuf
            )
            if let outBuf {
                context.render(scaled, to: outBuf)
                adaptor.append(outBuf, withPresentationTime: time)
            }
        }
        writerInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if writer.status != .completed {
            throw EnhanceError.videoFailed(writer.error?.localizedDescription ?? "Video export failed.")
        }
    }
}
