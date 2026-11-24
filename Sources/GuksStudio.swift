import AppKit
import CoreText
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct Frame: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var hold: Double? = nil
}

@MainActor
final class Studio: ObservableObject {
    @Published var frames: [Frame] = []
    @Published var selected: UUID?
    var draggedFrame: UUID?
    @Published var format: ExportFormat = .gif
    @Published var look: Look = .original
    @Published var motion: Motion = .dissolve
    @Published var canvas: Canvas = .first
    @Published var hold = 0.25
    @Published var fps = 30
    @Published var preset: SocialPreset = .custom
    @Published var playing = false
    private var lastTick: Date?
    @Published var position = 0.0
    @Published var cap: Int? = nil
    @Published var edge = 960
    @Published var pingPong = false
    @Published var fill = false
    @Published var loopGIF = true
    @Published var actualSize = false
    @Published var busy = false
    @Published var status = ""
    @Published var exportedURL: URL?
    @Published var failure: String?

    var index: Int? { frames.firstIndex { $0.id == selected } }
    var active: Frame? { index.map { frames[$0] } }
    var settings: ExportSettings {
        ExportSettings(format: format, look: look, canvas: canvas, delay: hold,
                       pingPong: pingPong, fill: fill, edge: edge, cap: format == .gif ? cap : nil, fps: fps, motion: motion, loopGIF: loopGIF)
    }
    var timeline: [TimedImage] {
        Renderer.sequence(frames.map { TimedImage(url: $0.url, hold: $0.hold ?? hold) }, pingPong: pingPong)
    }
    var duration: Double { timeline.reduce(0) { $0 + $1.hold } }
    var transition: (next: URL, progress: Double)? {
        let items = timeline
        guard items.count > 1, motion != .cut else { return nil }
        var start = 0.0
        for (index, item) in items.enumerated() {
            let end = start + item.hold
            if position < end {
                guard index < items.count - 1 || settings.repeats else { return nil }
                let length = Renderer.transitionDuration(item.hold, motion: motion)
                guard length > 0, position > end - length else { return nil }
                let progress = (position - (end - length)) / length
                return (items[(index + 1) % items.count].url, progress)
            }
            start = end
        }
        return nil
    }

    func applyPreset(_ preset: SocialPreset) {
        self.preset = preset
        guard preset != .custom else { return }
        format = preset.format
        canvas = preset.canvas
        edge = preset.edge
        cap = preset.cap
        fps = 30
        if preset.format == .gif { loopGIF = true }
    }

    func seek(_ value: Double) {
        position = min(max(0, value), duration)
        let sequence = timeline
        var cursor = 0.0
        let item = sequence.first { frame in
            cursor += frame.hold
            return position < cursor
        } ?? sequence.last
        if let item { selected = frames.first { $0.url == item.url }?.id }
    }

    func pick(_ id: UUID) {
        playing = false
        selected = id
        if let index { position = frames.prefix(index).reduce(0) { $0 + ($1.hold ?? hold) } }
    }

    func step(_ tick: Date) {
        guard playing, duration > 0 else { lastTick = nil; return }
        let elapsed = lastTick.map { max(0, tick.timeIntervalSince($0)) } ?? 0
        lastTick = tick
        let next = position + elapsed
        if !settings.repeats && next >= duration {
            seek(duration)
            playing = false
        } else {
            seek(next.truncatingRemainder(dividingBy: duration))
        }
    }

    func togglePlayback() {
        if !playing && position >= duration { seek(0) }
        lastTick = nil
        playing.toggle()
    }

    func choose(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = true
        if !folder { panel.allowedContentTypes = [.image] }
        present(panel) { response in
            if response == .OK { self.add(panel.urls) }
        }
    }

    func add(_ urls: [URL]) {
        let manager = FileManager.default
        let found = urls.flatMap { url -> [URL] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [url] }
            let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            return (enumerator?.compactMap { $0 as? URL } ?? []).filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }.filter {
            UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var existing = Set(frames.map(\.url))
        let additions = found.filter { existing.insert($0).inserted }.map { Frame(url: $0) }
        frames.append(contentsOf: additions)
        if selected == nil { selected = frames.first?.id }
        status = additions.isEmpty ? "No new images found." : ""
    }

    func move(_ amount: Int) {
        guard let index, frames.indices.contains(index + amount) else { return }
        frames.swapAt(index, index + amount)
    }

    func moveDraggedFrame(to target: UUID) {
        guard let draggedFrame, draggedFrame != target,
              let source = frames.firstIndex(where: { $0.id == draggedFrame }),
              let destination = frames.firstIndex(where: { $0.id == target }) else { return }
        frames.move(fromOffsets: IndexSet(integer: source), toOffset: destination > source ? destination + 1 : destination)
        pick(draggedFrame)
    }

    func remove() {
        guard let index else { return }
        frames.remove(at: index)
        selected = frames.isEmpty ? nil : frames[min(index, frames.count - 1)].id
    }

    var suggestedFilename: String {
        let firstName = frames.first?.url.deletingPathExtension().lastPathComponent ?? "Guks Studio"
        return firstName + "." + format.ext
    }

    private func present(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func save() {
        guard !busy, !frames.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = suggestedFilename
        let settings = self.settings
        let urls = frames.map(\.url)
        let holds = frames.map { $0.hold ?? hold }
        present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            self.exportedURL = nil
            self.busy = true
            self.status = "Exporting " + settings.format.rawValue + "…"
            Task {
                defer { self.busy = false }
                do {
                    let size = try await Task.detached(priority: .userInitiated) {
                        try Renderer.export(urls, to: url, settings: settings, holds: holds)
                    }.value
                    let amount = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    self.status = "Saved " + url.lastPathComponent + " · " + amount
                    self.exportedURL = url
                } catch {
                    self.status = ""
                    self.failure = error.localizedDescription
                }
            }
        }
    }
}

enum SocialPreset: String, CaseIterable, Identifiable {
    case custom = "Custom", xWeb = "Twitter GIF · Web", xMobile = "Twitter GIF · Mobile", xVideo = "Twitter video"
    case reels = "Instagram Reels", instagramFeed = "Instagram Feed", tiktok = "TikTok"
    case shorts = "YouTube Shorts", youtube = "YouTube · Landscape"
    var id: Self { self }
    var format: ExportFormat { [.xWeb, .xMobile].contains(self) ? .gif : .mp4 }
    var canvas: Canvas {
        switch self {
        case .xWeb, .xMobile, .custom: return .first
        case .instagramFeed: return .feed
        case .xVideo, .youtube: return .landscape
        default: return .portrait
        }
    }
    var edge: Int {
        switch self {
        case .xWeb, .xMobile: return 720
        case .instagramFeed: return 1350
        default: return 1920
        }
    }
    var cap: Int? {
        switch self {
        case .xWeb: return 15_000_000
        case .xMobile: return 5_000_000
        default: return nil
        }
    }
}

private let ink = Color.primary
private let muted = Color.secondary
private let line = Color(nsColor: .separatorColor)
private let shell = Color(nsColor: .windowBackgroundColor)
private let stageColor = Color(white: 0.038)
private let chip = Color(nsColor: .controlBackgroundColor)

private func loop(_ size: CGFloat = 14, _ weight: String = "Regular") -> Font {
    .custom("LOOPGrotesque-" + weight, size: size)
}

private enum PictureCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 150
        cache.totalCostLimit = 100_000_000
        return cache
    }()
    private static let aspects = NSCache<NSURL, NSNumber>()

    static func ratio(_ first: URL, canvas: Canvas) -> Double? {
        if canvas != .first {
            switch canvas {
            case .square: return 1
            case .feed: return 4.0 / 5
            case .portrait: return 9.0 / 16
            case .landscape: return 16.0 / 9
            case .first: break
            }
        }
        if let cached = aspects.object(forKey: first as NSURL) { return cached.doubleValue }
        guard let picture = try? Renderer.image(first, edge: 320) else { return nil }
        let ratio = canvas.ratio(first: picture)
        aspects.setObject(NSNumber(value: ratio), forKey: first as NSURL)
        return ratio
    }

    static func load(_ url: URL, size: (Int, Int)? = nil, settings: ExportSettings? = nil) -> NSImage? {
        let config = settings.map { "\($0.look.rawValue) \($0.fill)" } ?? "thumb"
        let key = (url.path + "|\(size?.0 ?? 0)x\(size?.1 ?? 0)|" + config) as NSString
        if let cached = images.object(forKey: key) { return cached }
        let image: CGImage?
        if let size, let settings { image = try? Renderer.preview(url, size: size, settings: settings) }
        else { image = try? Renderer.image(url, edge: 160) }
        guard let image else { return nil }
        let result = NSImage(cgImage: image, size: .zero)
        images.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }
}

private let sequenceFrameType = UTType(exportedAs: "local.guksstudio.sequence-frame")

@MainActor
private struct SequenceDrop: DropDelegate {
    let studio: Studio
    let target: UUID

    func validateDrop(info: DropInfo) -> Bool { studio.draggedFrame != nil }

    func dropEntered(info: DropInfo) {
        studio.moveDraggedFrame(to: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        studio.draggedFrame = nil
        return true
    }
}

struct StudioView: View {
    @StateObject private var studio = Studio()
    @Environment(\.displayScale) private var displayScale
    private let clock = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                preview
                divider
                transport
                divider
                filmstrip
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(line).frame(width: 1)
            inspector.frame(width: 340)
        }
        .background(shell)
        .foregroundStyle(ink)
        .font(loop())
        .frame(minWidth: 790, minHeight: 560)
        .toolbar {
            ToolbarItemGroup {
                Button { studio.choose(folder: false) } label: {
                    Label("Add Photos", systemImage: "photo.badge.plus")
                }.keyboardShortcut("o")
                Button { studio.choose(folder: true) } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
        .onReceive(clock, perform: studio.step)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in studio.add([url]) } }
                }
            }
            return !providers.isEmpty
        }
        .alert("Export failed", isPresented: Binding(get: { studio.failure != nil }, set: { if !$0 { studio.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(studio.failure ?? "") }
    }

    private var divider: some View { Rectangle().fill(line).frame(height: 1) }
    private var ratio: Double? {
        guard let first = studio.frames.first else { return nil }
        return PictureCache.ratio(first.url, canvas: studio.canvas)
    }

    private func sizeLabel(_ edge: Int) -> String {
        guard let ratio else { return "\(edge) px" }
        let (width, height) = Renderer.dimensions(ratio: ratio, edge: edge)
        return "\(width) × \(height) px"
    }

    private var previewPicture: (NSImage, NSImage?, Double)? {
        guard let active = studio.active, let ratio else { return nil }
        let size = Renderer.dimensions(ratio: ratio, edge: studio.actualSize ? studio.edge : min(studio.edge, 960))
        guard let image = PictureCache.load(active.url, size: size, settings: studio.settings) else { return nil }
        guard let transition = studio.transition,
              let next = PictureCache.load(transition.next, size: size, settings: studio.settings) else { return (image, nil, 0) }
        return (image, next, Renderer.eased(transition.progress))
    }

    private func previewImage(_ picture: (NSImage, NSImage?, Double)) -> some View {
        GeometryReader { bounds in
            let width = picture.0.size.width
            let height = picture.0.size.height
            if studio.actualSize {
                ScrollView([.horizontal, .vertical]) {
                    imageLayers(picture, width: width / displayScale, height: height / displayScale)
                        .padding(16)
                        .frame(minWidth: bounds.size.width, minHeight: bounds.size.height)
                }
            } else {
                let scale = max(0, min((bounds.size.width - 48) / width, (bounds.size.height - 48) / height))
                imageLayers(picture, width: width * scale, height: height * scale)
                    .frame(width: bounds.size.width, height: bounds.size.height)
            }
        }
    }

    private func imageLayers(_ picture: (NSImage, NSImage?, Double), width: CGFloat, height: CGFloat) -> some View {
        let (current, next, progress) = picture
        let sliding = studio.motion == .slide && next != nil
        return ZStack {
            Image(nsImage: current).resizable().frame(width: width, height: height)
                .offset(x: sliding ? -width * progress : 0)
            if let next {
                Image(nsImage: next).resizable().frame(width: width, height: height)
                    .scaleEffect(studio.motion == .zoom ? 1 - (1 - progress) * 0.17 : 1)
                    .opacity(sliding ? 1 : progress)
                    .offset(x: sliding ? width * (1 - progress) : 0)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay { Rectangle().strokeBorder(line, lineWidth: 1) }
    }

    private var preview: some View {
        ZStack {
            stageColor
            if let image = previewPicture {
                previewImage(image)
            } else if studio.frames.isEmpty {
                Button { studio.choose(folder: false) } label: {
                    VStack(spacing: 9) {
                        Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 31, weight: .light))
                            .padding(.bottom, 4)
                        Text("Choose Photos…").font(loop(19, "Medium")).foregroundStyle(.white)
                        Text("Or drag photos and folders here").font(loop(13))
                    }
                    .foregroundStyle(.white.opacity(0.67))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the image picker")
            } else {
                Text("Preview unavailable").font(loop(16, "Medium")).foregroundStyle(.white.opacity(0.67))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 13) {
            Button { studio.togglePlayback() } label: {
                Image(systemName: studio.playing ? "pause.fill" : "play.fill").frame(width: 16)
            }.help(studio.playing ? "Pause preview" : "Play preview")
                .disabled(studio.frames.isEmpty)
                .keyboardShortcut(.space, modifiers: [])
            Slider(value: Binding(get: { min(studio.position, studio.duration) }, set: {
                studio.playing = false
                studio.seek($0)
            }), in: 0...max(0.01, studio.duration))
            .accessibilityLabel("Preview position").disabled(studio.frames.isEmpty)
            Text(String(format: "%.2f / %.2f s", min(studio.position, studio.duration), studio.duration))
                .font(loop(12)).monospacedDigit().foregroundStyle(muted).fixedSize()
            if ratio != nil {
                Divider().frame(height: 16)
                Text(sizeLabel(studio.edge)).font(loop(12)).monospacedDigit().foregroundStyle(muted).fixedSize()
                Button(studio.actualSize ? "100%" : "Fit") { studio.actualSize.toggle() }
                    .font(loop(12, "Medium")).fixedSize()
                    .help(studio.actualSize ? "Fit the preview in the window" : "See the preview at actual pixel size")
                    .accessibilityLabel(studio.actualSize ? "Actual pixel size" : "Fit preview")
            }
        }.buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 42)
    }

    private var filmstrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Sequence").font(loop(14, "Medium"))
                Text("\(studio.frames.count)").monospacedDigit().foregroundStyle(muted)
                Spacer()
                Button { studio.move(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Move earlier").disabled((studio.index ?? 0) == 0)
                Button { studio.move(1) } label: { Image(systemName: "chevron.right") }
                    .help("Move later").disabled((studio.index ?? studio.frames.count) >= studio.frames.count - 1)
                Button { studio.frames.reverse() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Reverse order").disabled(studio.frames.count < 2)
                Button { studio.remove() } label: { Image(systemName: "minus") }
                    .help("Remove selected image").disabled(studio.active == nil)
            }.buttonStyle(.borderless)
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 7) {
                    ForEach(studio.frames) { frame in
                        Button { studio.pick(frame.id) } label: {
                            ZStack(alignment: .bottomTrailing) {
                                RoundedRectangle(cornerRadius: 4).fill(chip)
                                if let image = PictureCache.load(frame.url) {
                                    Image(nsImage: image).resizable().scaledToFill()
                                        .frame(width: 84, height: 59).clipped()
                                }
                                Text(String(format: "%.2fs", frame.hold ?? studio.hold))
                                    .font(loop(11, "Medium")).foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(.black.opacity(0.75))
                            }.frame(width: 84, height: 59)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(studio.selected == frame.id ? ink : line,
                                                                                    lineWidth: studio.selected == frame.id ? 2 : 1))
                        }.buttonStyle(.plain).help(frame.url.lastPathComponent + " · Drag to reorder")
                            .accessibilityLabel(frame.url.lastPathComponent)
                            .accessibilityAddTraits(studio.selected == frame.id ? .isSelected : [])
                            .onDrag {
                                studio.pick(frame.id)
                                studio.draggedFrame = frame.id
                                let provider = NSItemProvider()
                                provider.registerDataRepresentation(forTypeIdentifier: sequenceFrameType.identifier,
                                                                    visibility: .ownProcess) { complete in
                                    complete(Data(frame.id.uuidString.utf8), nil)
                                    return nil
                                }
                                return provider
                            }
                            .onDrop(of: [sequenceFrameType], delegate: SequenceDrop(studio: studio, target: frame.id))
                    }
                }
            }.frame(height: 67)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private let timingRange = 0.05...10.0

    private func timingField(_ title: String, value: Binding<Double>) -> some View {
        let seconds = Binding(get: { value.wrappedValue }, set: { entered in
            guard entered.isFinite else { return }
            let bounded = min(max(entered, timingRange.lowerBound), timingRange.upperBound)
            value.wrappedValue = (bounded * 100).rounded() / 100
        })
        return LabeledContent(title) {
            HStack(spacing: 5) {
                TextField(title, value: seconds, format: .number.precision(.fractionLength(2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .accessibilityLabel(title + " in seconds")
                    .help("Type a duration from 0.05 to 10 seconds")
                Text("s").foregroundStyle(muted).accessibilityHidden(true)
                Stepper(value: seconds, in: timingRange, step: 0.05) { Text(title) }
                    .labelsHidden()
            }
        }
    }

    private func frameHold(for frame: Frame) -> Binding<Double> {
        Binding(get: {
            studio.frames.first { $0.id == frame.id }?.hold ?? studio.hold
        }, set: { value in
            if let index = studio.frames.firstIndex(where: { $0.id == frame.id }) {
                studio.frames[index].hold = value
            }
        })
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Export") {
                    Picker("Post to", selection: Binding(get: { studio.preset }, set: studio.applyPreset)) {
                        ForEach(SocialPreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Format", selection: $studio.format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                Section("Framing") {
                    Picker("Shape", selection: $studio.canvas) {
                        ForEach(Canvas.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Output size", selection: $studio.edge) {
                        ForEach([480, 720, 960, 1080, 1350, 1440, 1920], id: \.self) { Text(sizeLabel($0)).tag($0) }
                    }.help("Controls the dimensions of the saved file. Switch the preview from Fit to 100% to see actual pixels.")
                    Picker("Photo fit", selection: $studio.fill) {
                        Text("Show whole photo").tag(false)
                        Text("Crop to fill").tag(true)
                    }.help("Show whole photo keeps every edge. Crop to fill trims edges if the photo and frame have different shapes.")
                    Picker("Color", selection: $studio.look) {
                        ForEach(Look.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Playback") {
                    Picker("Transition", selection: $studio.motion) {
                        ForEach(Motion.allCases) { Text($0.rawValue).tag($0) }
                    }
                    timingField("Time per image", value: $studio.hold)
                    if let frame = studio.active {
                        timingField("Selected image", value: frameHold(for: frame)).id(frame.id)
                        if studio.active?.hold != nil {
                            Button("Use sequence timing") {
                                if let index = studio.index { studio.frames[index].hold = nil }
                            }.buttonStyle(.borderless).foregroundStyle(muted)
                        }
                    }
                    if studio.format == .mp4 {
                        Picker("Frames per second", selection: $studio.fps) {
                            ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                        }
                    } else {
                        Toggle("Loop GIF", isOn: $studio.loopGIF)
                        Text(studio.loopGIF ? "Starts over at the end." : "Plays once and stops.")
                            .font(loop(12)).foregroundStyle(muted)
                        Picker("File size limit", selection: $studio.cap) {
                            Text("None").tag(nil as Int?)
                            Text("Twitter web · Under 15 MB").tag(15_000_000 as Int?)
                            Text("Twitter mobile · Under 5 MB").tag(5_000_000 as Int?)
                        }
                    }
                    Toggle("Play forward and back", isOn: $studio.pingPong)
                }
            }
            .formStyle(.grouped)
            divider
            VStack(alignment: .leading, spacing: 10) {
                if studio.busy {
                    ProgressView(studio.status).controlSize(.small)
                } else if !studio.status.isEmpty {
                    HStack {
                        Text(studio.status).font(loop(12)).foregroundStyle(muted).lineLimit(2)
                        if let url = studio.exportedURL {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                                Label("Show in Finder", systemImage: "folder").labelStyle(.iconOnly)
                            }.buttonStyle(.borderless).help("Show in Finder")
                        }
                    }
                }
                Button { studio.save() } label: {
                    Text("Export " + studio.format.rawValue + "…")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(studio.busy || studio.frames.isEmpty)
                    .keyboardShortcut("s")
            }.padding(16).background(.regularMaterial)
        }
    }
}

@main
struct GuksStudioApp: App {
    init() {
        for weight in ["Regular", "Medium", "SemiBold"] {
            if let url = Bundle.main.url(forResource: "Loop-" + weight, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Guks Studio") { StudioView() }
            .defaultSize(width: 920, height: 680)
    }
}
