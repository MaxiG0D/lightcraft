import CoreGraphics
import Foundation
import ImageIO
import Observation
import Photos
import UniformTypeIdentifiers

/// The app's state over one LightCraft library. Every action is an engine command (the same ids and
/// parameters as the desktop app: `develop.set`, `preset.apply`, `edit.undo`, `library.import`, …);
/// after one, the model re-reads what it shows from the engine.
///
/// Rendering runs off the main actor; while one render is in flight, slider changes only mark the
/// preview stale, and the next render starts with the latest values when it finishes.
@MainActor
@Observable
final class AppModel {
    enum ViewMode { case grid, detail }
    enum Panel: String, CaseIterable, Identifiable {
        case edit, presets, history
        var id: String { rawValue }
        var title: String {
            switch self {
            case .edit: "Edit"
            case .presets: "Presets"
            case .history: "History"
            }
        }
        var icon: LCIcon {
            switch self {
            case .edit: .sliders
            case .presets: .presets
            case .history: .clock
            }
        }
    }
    /// A tool that samples the photo where it is tapped.
    enum Tool { case none, whiteBalance, pointColor }

    let layout = PanelLayout.shared
    let whiteBalanceModes: [WbModeItem] = (try? wbModes()) ?? []

    private(set) var engine: Engine?
    private(set) var photos: [LibraryPhoto] = []
    private(set) var activeID: UInt64?
    var mode: ViewMode = .grid
    var panel: Panel = .edit
    var tool: Tool = .none

    private(set) var photo: PhotoState?
    private(set) var settings = SettingsJSON("{}")
    private(set) var controls: [String: ControlInfo] = [:]
    /// Bumped after every change to the active photo's settings (editors re-read their data).
    private(set) var revision = 0
    private(set) var undoLabel: String?
    private(set) var redoLabel: String?
    private(set) var presets: [PresetItem] = []
    private(set) var profiles: ProfilesMenu?
    private(set) var history: HistoryList?

    private(set) var preview: CGImage?
    private(set) var original: CGImage?
    private(set) var histogram: Histogram?
    private(set) var thumbnails: [UInt64: CGImage] = [:]
    private(set) var isBusy = false
    private(set) var toast: String?
    var error: String?
    /// Show the photo's "before" state (press and hold the photo, or the Before/After button).
    var showingOriginal = false { didSet { if showingOriginal { loadOriginal() } } }
    /// A slider is being dragged: render at draft quality, then once at full quality on release.
    private(set) var dragging = false
    /// Long edge of on-screen previews, from the canvas size (set by the view).
    var previewEdge: UInt32 = 1600

    private var rendering = false
    private var pending: Bool?  // nil: nothing pending; else draft?
    private var thumbsLoading: Set<UInt64> = []
    private var toastTask: Task<Void, Never>?

    nonisolated static let thumbnailEdge: UInt32 = 320

    init() {
        do {
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("LightCraft", isDirectory: true)
            let library = support.appendingPathComponent("Library", isDirectory: true)
            let models = support.appendingPathComponent("Models", isDirectory: true)
            try fm.createDirectory(at: library, withIntermediateDirectories: true)
            try fm.createDirectory(at: models, withIntermediateDirectories: true)
            // the caches' budget: a quarter of the device's memory, as on desktop, but at most 1 GB
            let quarter = ProcessInfo.processInfo.physicalMemory / 4 / (1 << 20)
            engine = try Engine.open(libraryDir: library.path, modelsDir: models.path, memoryMb: UInt32(min(max(quarter, 256), 1024)))
        } catch {
            self.error = "Couldn't open the library: \(describe(error))"
        }
        reloadPresets()
        profiles = decode("profiles.menu", as: ProfilesMenu.self)
        reloadLibrary()
        if let active = activeID ?? photos.first?.id { select(active, open: false) }
    }

    // MARK: commands

    /// Run an engine command. Errors become the alert; the result is the command's JSON text.
    @discardableResult
    func run(_ command: String, _ params: [String: Any] = [:]) -> String? {
        guard let engine else { return nil }
        do {
            return try engine.call(command: command, paramsJson: jsonString(params))
        } catch {
            self.error = describe(error)
            return nil
        }
    }

    func decode<T: Decodable>(_ command: String, _ params: [String: Any] = [:], as type: T.Type) -> T? {
        guard let engine, let json = try? engine.call(command: command, paramsJson: jsonString(params)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    /// Run a command that changes the active photo's settings, then show the result.
    func edit(_ command: String, _ params: [String: Any] = [:]) {
        guard run(command, params) != nil else { return }
        afterEdit()
    }

    func reloadPresets() {
        presets = decode("presets.list", as: [PresetItem].self) ?? []
    }

    // MARK: library

    func reloadLibrary() {
        photos = decode("catalog.query", as: CatalogPage.self)?.photos ?? []
        if let state = decode("library.state", as: LibraryState.self) {
            activeID = state.selection.active
            undoLabel = state.undo
            redoLabel = state.redo
        }
    }

    var activePhoto: LibraryPhoto? { photos.first { $0.id == activeID } }

    /// Make `id` the active photo (the desktop's selection); `open`: show it in the Detail view.
    func select(_ id: UInt64, open: Bool = true) {
        if id != activeID {
            guard run("library.select", ["ids": [id], "active": id]) != nil else { return }
            activeID = id
            preview = nil
            original = nil
            histogram = nil
            showingOriginal = false
            tool = .none
        }
        refreshPhoto()
        if open { mode = .detail }
        requestRender(draft: false)
    }

    /// Import picked files (copied into the library, as the desktop's Import with "Copy").
    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        let paths = urls.map(\.path)
        guard let json = run("library.import", ["paths": paths, "mode": "copy"]),
              let result = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return }
        let imported = (result["imported"] as? [Any])?.compactMap { ($0 as? NSNumber)?.uint64Value } ?? []
        let failed = (result["failed"] as? [Any])?.count ?? 0
        let duplicates = (result["duplicates"] as? [Any])?.count ?? 0
        // the temporary copies (each in its own folder)
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        reloadLibrary()
        var parts = ["Imported \(imported.count) photo\(imported.count == 1 ? "" : "s")"]
        if duplicates > 0 { parts.append("\(duplicates) already in the library") }
        if failed > 0 { parts.append("\(failed) couldn't be read") }
        showToast(parts.joined(separator: ", "))
        if let first = imported.first { select(first, open: imported.count == 1) }
        save()
    }

    func rate(_ rating: Int) {
        guard let id = activeID else { return }
        let current = activePhoto?.rating ?? 0
        // tapping the current rating clears it, as clicking a star does on desktop
        run("photo.rate", ["rating": rating == current ? 0 : rating, "ids": [id]])
        reloadLibrary()
    }

    func flag(_ flag: String) {
        guard let id = activeID else { return }
        run("photo.flag", ["flag": activePhoto?.flag == flag ? "none" : flag, "ids": [id]])
        reloadLibrary()
    }

    func undo() {
        guard run("edit.undo") != nil else { return }
        afterUndo()
    }

    func redo() {
        guard run("edit.redo") != nil else { return }
        afterUndo()
    }

    private func afterUndo() {
        let before = photos.map(\.id)
        reloadLibrary()
        // an undone import changes the photos; an undone edit the active photo
        if photos.map(\.id) != before, let id = activeID ?? photos.first?.id {
            select(id, open: mode == .detail)
        } else {
            afterEdit()
        }
    }

    func save() {
        guard let engine else { return }
        Task.detached(priority: .utility) { try? engine.save() }
    }

    // MARK: the active photo

    func refreshPhoto() {
        guard let engine else { return }
        photo = (try? engine.photoState()) ?? nil
        settings = SettingsJSON(photo?.settingsJson ?? "{}")
        controls = Dictionary(((try? engine.controls()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        history = decode("history.list", as: HistoryList.self)
        if let state = decode("library.state", as: LibraryState.self) {
            undoLabel = state.undo
            redoLabel = state.redo
        }
        revision += 1
    }

    private func afterEdit() {
        refreshPhoto()
        requestRender(draft: false)
    }

    var relativeWB: Bool { photo?.relativeWb ?? true }

    func value(_ id: String) -> Double { controls[id]?.value ?? 0 }

    /// Set a slider (through `develop.set`). During a drag only that value is re-read.
    func setValue(_ id: String, _ v: Double) {
        guard let engine, activeID != nil else { return }
        do {
            let kept = try engine.setValue(id: id, value: v)
            guard kept != controls[id]?.value || !dragging else { return }
            controls[id]?.value = kept
        } catch {
            self.error = describe(error)
            return
        }
        if dragging {
            requestRender(draft: true)
        } else {
            afterEdit()
        }
    }

    /// Set several controls at once (one undo step), e.g. a grading wheel's hue and saturation.
    func setValues(_ values: [String: Double]) {
        guard run("develop.set", ["values": values]) != nil else { return }
        for (id, v) in values { controls[id]?.value = v }
        if dragging { requestRender(draft: true) } else { afterEdit() }
    }

    /// A slider drag, a curve point drag or a wheel drag: one undo step, as on desktop.
    func beginDrag(_ label: String) {
        guard !dragging else { return }
        dragging = true
        run("develop.beginInteraction", ["label": label])
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        run("develop.endInteraction")
        afterEdit()
    }

    func curve(_ channel: String) -> CurveInfo? { try? engine?.curve(channel: channel) }

    /// Set a point curve (`develop.curve`); during a drag, renders at draft quality.
    func setCurve(_ channel: String, _ points: [CGPoint]) {
        guard run("develop.curve", ["channel": channel, "points": points.map { [Double($0.x), Double($0.y)] }]) != nil else { return }
        if dragging { requestRender(draft: true) } else { afterEdit() }
    }

    /// A tap on the photo with a sampling tool: `x`, `y` normalized to the shown image.
    func sample(x: Double, y: Double) {
        switch tool {
        case .whiteBalance: edit("develop.wbPick", ["x": x, "y": y])
        case .pointColor: edit("pointColor.pick", ["x": x, "y": y])
        case .none: return
        }
        tool = .none
    }

    func applyPreset(_ preset: PresetItem) {
        edit("preset.apply", ["id": preset.id])
        showToast("Preset: \(preset.name)")
    }

    func exportToPhotos() async {
        guard let id = activeID else { return }
        isBusy = true
        defer { isBusy = false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // the desktop's export: full size JPEG, metadata kept
        guard let json = run("app.export", ["ids": [id], "dir": dir.path, "format": "jpeg", "quality": 92, "longEdge": 0]),
              let result = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let path = result["path"] as? String ?? ((result["files"] as? [[String: Any]])?.first?["path"] as? String)
        else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            error = "Allow LightCraft to add photos in Settings ▸ Privacy & Security ▸ Photos."
            return
        }
        do {
            try await Self.saveToPhotos(URL(fileURLWithPath: path))
            showToast("Exported to Photos")
        } catch {
            self.error = "Export failed: \(describe(error))"
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: rendering

    func requestRender(draft: Bool) {
        guard activeID != nil else { return }
        if rendering {
            // a full-quality request wins over a draft one
            pending = (pending ?? true) && draft
            return
        }
        render(draft: draft)
    }

    private func render(draft: Bool) {
        guard let engine, let id = activeID else { return }
        rendering = true
        let edge = previewEdge
        Task.detached(priority: .userInitiated) {
            let result = Result { try engine.render(photo: id, maxEdge: edge, draft: draft, before: false) }
            let image = (try? result.get()).flatMap(Self.cgImage)
            await MainActor.run {
                self.rendering = false
                if self.activeID == id {
                    switch result {
                    case .success(let p):
                        self.preview = image
                        self.histogram = p.histogram
                        if !draft { self.reloadThumbnail(id) }
                    case .failure(let error):
                        self.error = "Render failed: \(describe(error))"
                    }
                }
                if let next = self.pending {
                    self.pending = nil
                    self.render(draft: next)
                }
            }
        }
    }

    private func loadOriginal() {
        guard let engine, let id = activeID else { return }
        let edge = previewEdge
        Task.detached(priority: .userInitiated) {
            let image = (try? engine.render(photo: id, maxEdge: edge, draft: false, before: true)).flatMap(Self.cgImage)
            await MainActor.run {
                if self.activeID == id { self.original = image }
            }
        }
    }

    /// The grid / filmstrip thumbnail of `id`, loading it when missing.
    func thumbnail(_ id: UInt64) -> CGImage? {
        if thumbnails[id] == nil { loadThumbnail(id) }
        return thumbnails[id]
    }

    private func reloadThumbnail(_ id: UInt64) {
        thumbsLoading.remove(id)
        loadThumbnail(id)
    }

    private func loadThumbnail(_ id: UInt64) {
        guard let engine, !thumbsLoading.contains(id) else { return }
        thumbsLoading.insert(id)
        Task.detached(priority: .utility) {
            let image = (try? engine.thumbnail(photo: id, edge: Self.thumbnailEdge)).flatMap(Self.cgImage)
            await MainActor.run {
                if let image { self.thumbnails[id] = image }
            }
        }
    }

    // MARK: helpers (off the main actor)

    /// Photos runs the change block on its own queue: it must not inherit the main actor's isolation.
    nonisolated private static func saveToPhotos(_ file: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
        }
    }

    nonisolated static func cgImage(_ p: Preview) -> CGImage? {
        let (w, h) = (Int(p.width), Int(p.height))
        guard w > 0, h > 0, p.rgba.count >= w * h * 4,
              let provider = CGDataProvider(data: p.rgba as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// HEIC needs the bridge's `heif` feature (off by default, see ios/README.md): without it,
    /// ImageIO turns HEIC into a high-quality JPEG with the same metadata before import.
    nonisolated static func importable(_ file: URL) -> URL {
        let ext = file.pathExtension.lowercased()
        guard ["heic", "heif", "hif"].contains(ext),
              let src = CGImageSourceCreateWithURL(file as CFURL, nil)
        else { return file }
        let out = file.deletingPathExtension().appendingPathExtension("jpg")
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return file }
        CGImageDestinationAddImageFromSource(dst, src, 0, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return file }
        try? FileManager.default.removeItem(at: file)
        return out
    }
}

/// The engine's own message for a bridge error (uniffi's default description is the enum's dump).
func describe(_ error: Error) -> String {
    switch error as? LcError {
    case .Unsupported(let msg), .Command(let msg), .Library(let msg), .Render(let msg): msg
    case nil: error.localizedDescription
    }
}
