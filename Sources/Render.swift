import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case gif = "GIF", mp4 = "MP4"
    var id: Self { self }
    var ext: String { rawValue.lowercased() }
    var type: UTType { self == .gif ? .gif : .mpeg4Movie }
}

enum Look: String, CaseIterable, Identifiable {
    case original = "Original", mono = "Black and white", warm = "Warm"
    var id: Self { self }
}

enum Motion: String, CaseIterable, Identifiable {
    case cut = "Hard cut", dissolve = "Dissolve", slide = "Slide left", zoom = "Zoom in"
    var id: Self { self }
}

enum Canvas: String, CaseIterable, Identifiable {
    case first = "Same as first photo", square = "Square · 1:1", feed = "Portrait feed · 4:5", portrait = "Full portrait · 9:16", landscape = "Landscape · 16:9"
    var id: Self { self }

    func ratio(first: CGImage) -> Double {
        switch self {
        case .first: return Double(first.width) / Double(first.height)
        case .square: return 1
        case .feed: return 4.0 / 5
        case .portrait: return 9.0 / 16
        case .landscape: return 16.0 / 9
        }
    }
}

struct ExportSettings {
    let format: ExportFormat
    let look: Look
    let canvas: Canvas
    let delay: Double
    let pingPong: Bool
    let fill: Bool
    let edge: Int
    let cap: Int?
    var fps: Int = 30
    var motion: Motion = .cut
    var loopGIF = true
    var repeats: Bool { format == .gif && loopGIF }
}

enum RenderError: LocalizedError {
    case unreadable(String), encoder(String), tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Couldn’t open \(name) as an image."
        case .encoder(let detail): return detail
        case .tooLarge: return "This sequence could not fit under the size limit. Try fewer images."
        }
    }
}

private struct Sample {
    let image: URL
    let next: URL?
    let progress: Double
    let hold: Double
}

struct TimedImage {
    let url: URL
    let hold: Double
}

enum Renderer {
    static func sequence(_ images: [TimedImage], pingPong: Bool) -> [TimedImage] {
        pingPong && images.count > 2 ? images + images.dropFirst().dropLast().reversed() : images
    }

    static func transitionDuration(_ hold: Double, motion: Motion) -> Double {
        guard motion != .cut, hold >= 0.10 else { return 0 }
        return min(0.40, hold * 0.68)
    }

    static func eased(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }

    private static func samples(_ images: [TimedImage], motion: Motion, repeats: Bool, rate: Int) -> [Sample] {
        images.enumerated().flatMap { index, image -> [Sample] in
            let connects = images.count > 1 && (index < images.count - 1 || repeats)
            let duration = connects ? transitionDuration(image.hold, motion: motion) : 0
            let first = Sample(image: image.url, next: nil, progress: 0, hold: image.hold - duration)
            guard duration > 0 else { return [first] }
            let next = images[(index + 1) % images.count].url
            let count = max(1, Int(duration * Double(rate)))
            return [first] + (1...count).map { step in
                Sample(image: image.url, next: next, progress: Double(step) / Double(count + 1),
                       hold: duration / Double(count))
            }
        }
    }

    static func preview(_ url: URL, size: (Int, Int), settings: ExportSettings) throws -> CGImage {
        let (width, height) = size
        let image = try image(url, edge: max(width, height) * 2)
        return try compose(image, width: width, height: height, s: settings, context: previewContext)
    }

    private static let previewContext = CIContext(options: [.cacheIntermediates: false])

    static func dimensions(ratio: Double, edge: Int) -> (Int, Int) {
        let w = ratio >= 1 ? edge : Int(Double(edge) * ratio)
        let h = ratio >= 1 ? Int(Double(edge) / ratio) : edge
        return (max(2, (w / 2) * 2), max(2, (h / 2) * 2))
    }
    static func image(_ url: URL, edge: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary)
        else { throw RenderError.unreadable(url.lastPathComponent) }
        return picture
    }

    static func export(_ urls: [URL], to output: URL, settings s: ExportSettings, holds: [Double]? = nil) throws -> Int {
        guard let first = urls.first else { throw RenderError.encoder("Add at least one image.") }
        let ratio = s.canvas.ratio(first: try image(first, edge: 320))
        let frames = sequence(urls.enumerated().map { index, url in
            TimedImage(url: url, hold: holds.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? s.delay)
        }, pingPong: s.pingPong)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(s.format.ext)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let edges = s.format == .gif && s.cap != nil ? [s.edge, s.edge * 3 / 4, s.edge / 2, s.edge / 3, 160, 96, 48] : [s.edge]
        for edge in Array(Set(edges.filter { $0 <= s.edge })).sorted(by: >) {
            if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
            let (width, height) = dimensions(ratio: ratio, edge: edge)
            let context = CIContext(options: [.cacheIntermediates: false])
            func frame(_ url: URL) throws -> CGImage {
                let picture = try image(url, edge: max(width, height) * 2)
                return try compose(picture, width: width, height: height, s: s, context: context)
            }
            let cache = NSCache<NSURL, CGImage>()
            cache.totalCostLimit = 64_000_000
            func cached(_ url: URL) throws -> CGImage {
                if let hit = cache.object(forKey: url as NSURL) { return hit }
                let picture = try frame(url)
                cache.setObject(picture, forKey: url as NSURL, cost: picture.bytesPerRow * picture.height)
                return picture
            }
            let renders = samples(frames, motion: s.motion, repeats: s.repeats, rate: s.format == .gif ? 50 : s.fps)
            func produce(_ sample: Sample) throws -> CGImage {
                let current = try cached(sample.image)
                guard let next = sample.next else { return current }
                return try blend(current, cached(next), progress: eased(sample.progress), motion: s.motion)
            }
            if s.format == .gif {
                try gif(renders, to: temporary, repeats: s.repeats, frame: produce)
            } else {
                try video(renders, to: temporary, width: width, height: height, fps: s.fps, frame: produce)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            guard let size = (attributes[.size] as? NSNumber)?.intValue, size > 0 else {
                throw RenderError.encoder("The encoder produced an empty file.")
            }
            if let cap = s.cap, size >= cap { continue }
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: output)
            }
            return size
        }
        throw RenderError.tooLarge
    }

    private static func compose(_ source: CGImage, width: Int, height: Int, s: ExportSettings, context: CIContext) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RenderError.encoder("Couldn’t prepare the output canvas.") }
        canvas.setFillColor(gray: 0.05, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .high
        let image = CIImage(cgImage: source)
        let filtered: CIImage
        switch s.look {
        case .original: filtered = image
        case .mono: filtered = image.applyingFilter("CIPhotoEffectMono")
        case .warm: filtered = image.applyingFilter("CIPhotoEffectInstant")
        }
        let picture = s.look == .original ? source : context.createCGImage(filtered, from: image.extent) ?? source
        let sx = Double(width) / Double(picture.width), sy = Double(height) / Double(picture.height)
        let scale = s.fill ? max(sx, sy) : min(sx, sy)
        let w = Double(picture.width) * scale, h = Double(picture.height) * scale
        canvas.draw(picture, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
        guard let result = canvas.makeImage() else { throw RenderError.encoder("Couldn’t render a frame.") }
        return result
    }

    static func blend(_ current: CGImage, _ next: CGImage, progress: Double, motion: Motion) throws -> CGImage {
        let width = Double(current.width), height = Double(current.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: current.width, height: current.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RenderError.encoder("Couldn’t render the transition.") }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        switch motion {
        case .cut:
            return current
        case .dissolve:
            context.draw(current, in: full)
            context.setAlpha(progress)
            context.draw(next, in: full)
        case .slide:
            let offset = (width * progress).rounded()
            context.draw(current, in: full.offsetBy(dx: -offset, dy: 0))
            context.draw(next, in: full.offsetBy(dx: width - offset, dy: 0))
        case .zoom:
            context.draw(current, in: full)
            let scale = (1 - progress) * 0.17
            context.setAlpha(progress)
            context.draw(next, in: full.insetBy(dx: width * scale / 2, dy: height * scale / 2))
        }
        guard let result = context.makeImage() else { throw RenderError.encoder("Couldn’t render the transition.") }
        return result
    }

    private static func gif(_ images: [Sample], to output: URL, repeats: Bool, frame: (Sample) throws -> CGImage) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, images.count, nil)
        else { throw RenderError.encoder("Couldn’t create the GIF.") }
        if repeats {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        var elapsed = 0.0
        var ticks = 0
        for image in images {
            elapsed += image.hold
            let next = Int((elapsed * 100).rounded())
            let delay = Double(next - ticks) / 100
            ticks = next
            let properties = [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay
            ]] as CFDictionary
            try autoreleasepool { CGImageDestinationAddImage(destination, try frame(image), properties) }
        }
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encoder("Couldn’t finish the GIF.") }
    }

    private static func video(_ images: [Sample], to output: URL, width: Int, height: Int, fps: Int,
                              frame: (Sample) throws -> CGImage) throws {
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(500_000, width * height * 5)]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw RenderError.encoder("H.264 encoding is unavailable for this size.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RenderError.encoder("Couldn’t start the MP4 encoder.") }
        writer.startSession(atSourceTime: .zero)
        var elapsed = 0.0
        var nextTick = 0
        let timeScale = Int32(fps)
        do {
            for image in images {
                let startTick = nextTick
                elapsed += image.hold
                nextTick = max(startTick + 1, Int((elapsed * Double(fps)).rounded()))
                try autoreleasepool {
                    guard let pool = adaptor.pixelBufferPool else { throw RenderError.encoder("Couldn’t create a video frame.") }
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                        throw RenderError.encoder("Couldn’t allocate a video frame.")
                    }
                    let picture = try frame(image)
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
                    context?.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    guard context != nil else { throw RenderError.encoder("Couldn’t draw the video frame.") }
                    for time in startTick..<nextTick {
                        let started = Date()
                        while !input.isReadyForMoreMediaData {
                            if writer.status != .writing || Date().timeIntervalSince(started) > 10 {
                                throw writer.error ?? RenderError.encoder("The video encoder stopped responding.")
                            }
                            Thread.sleep(forTimeInterval: 0.003)
                        }
                        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(time), timescale: timeScale))
                        else { throw writer.error ?? RenderError.encoder("Couldn’t write a video frame.") }
                    }
                }
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(nextTick), timescale: timeScale))
            input.markAsFinished()
            let finished = DispatchSemaphore(value: 0)
            writer.finishWriting { finished.signal() }
            guard finished.wait(timeout: .now() + 60) == .success, writer.status == .completed
            else { throw writer.error ?? RenderError.encoder("Couldn’t finish the MP4.") }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }
}
