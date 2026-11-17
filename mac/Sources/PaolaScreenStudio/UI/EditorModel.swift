import AVFoundation
import AppKit

/// Timeline lanes that hold items.
enum EditorLane {
    case zoom, edits, camera, annotations
}

/// What is selected on the timeline.
enum EditorSelection: Equatable {
    case zoom(UUID)
    case edit(UUID)
    case camera(UUID)
    case annotation(UUID)

    var id: UUID {
        switch self {
        case .zoom(let id), .edit(let id), .camera(let id), .annotation(let id): id
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let folder: URL
    let player = AVPlayer()

    @Published var settings: EditSettings {
        didSet {
            guard settings != oldValue else { return }
            recordUndo(oldValue)
            settingsChanged()
        }
    }
    @Published private(set) var cursor: CursorTrack
    @Published private(set) var flags: [Double]
    @Published private(set) var keystrokes: [KeyStroke]
    /// Length of the original recording; every edit is stored in this time.
    @Published private(set) var duration: Double = 0
    /// Length of the final video (after cuts, speed, intro and outro).
    @Published private(set) var finalDuration: Double = 0
    @Published private(set) var sourceSize: CGSize = .zero
    /// Playhead in recording time.
    @Published private(set) var currentTime: Double = 0
    /// Playhead in final-video time.
    @Published private(set) var playerTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var hasCamera = false
    @Published private(set) var isDirty = false
    @Published private(set) var exportProgress: Double?
    @Published private(set) var presets: [StylePreset] = []
    @Published var selection: EditorSelection?
    @Published var message: String?
    /// Peak level per bucket of the recording's audio (0...1), for the timeline.
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var undoStack: [EditSettings] = []
    @Published private(set) var redoStack: [EditSettings] = []
    @Published var playbackRate: Float = 1 {
        didSet { if player.rate != 0 { player.rate = playbackRate } }
    }
    @Published var previewQuality: PreviewQuality = .full {
        didSet { if previewQuality != oldValue, let item = player.currentItem { configure(item); seekEdited(playerTime) } }
    }

    enum PreviewQuality: String, CaseIterable, Identifiable {
        case full, half, quarter

        var id: String { rawValue }
        var maxDimension: CGFloat {
            switch self {
            case .full: 2560
            case .half: 1280
            case .quarter: 720
            }
        }
    }

    /// Set by ⌘E; the view opens the export sheet.
    @Published var exportRequested = false

    /// Copied/cut timeline item (shared by all editor windows).
    private static var clipboard: ClipboardItem?

    private enum ClipboardItem {
        case zoom(ZoomSegment)
        case edit(TimeEdit)
        case camera(CameraLayoutSegment)
        case annotation(Annotation)
    }

    private var restoringHistory = false
    private var lastUndoPush = Date.distantPast

    private var data: ProjectData
    private let sprite: CursorSprite?
    private var base: RecordingTimeline?
    private var timeline: RecordingTimeline?
    private var builtStructure: EditSettings.StructureKey?
    private var rebuildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?

    init(folder: URL) throws {
        let data = try ProjectStore.load(from: folder)
        self.folder = folder
        self.data = data
        self.settings = data.settings
        self.cursor = data.cursor
        self.flags = data.flags ?? []
        self.keystrokes = data.keystrokes ?? []
        self.sprite = CursorSprite.systemArrow()
        reloadPresets()
    }

    var title: String { folder.lastPathComponent }
    var trimEnd: Double { min(settings.trimEnd ?? duration, duration) }
    private var timeMap: TimeMap { timeline?.timeMap ?? .identity(duration: duration) }

    func load() async {
        Wallpaper.refresh()
        do {
            let base = try await ProjectStore.baseTimeline(for: folder, data: data)
            self.base = base
            hasCamera = base.cameraTrackID != nil
            sourceSize = base.sourceSize
            duration = base.duration
            // Older projects could contain overlapping zooms; fix them once.
            let normalized = ZoomEditing.normalized(settings.zoomSegments, duration: duration)
            if normalized != settings.zoomSegments { settings.zoomSegments = normalized }

            // Follow the real playback state so the play button never gets stuck (e.g. at the end).
            statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let playing = player.timeControlStatus != .paused
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.isPlaying = playing } }
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.playerTime = time.seconds
                    self.currentTime = self.timeMap.source(atEdited: time.seconds)
                }
            }
            await rebuild()
            undoStack = []
            redoStack = []
            waveform = await AudioEffects.waveform(for: base.composition)
        } catch {
            message = "\(tr("error.open_project")) \(error.localizedDescription)"
        }
    }

    // MARK: Undo

    /// Changes less than 0.7 s apart (e.g. one drag) form a single undo step.
    private func recordUndo(_ previous: EditSettings) {
        guard !restoringHistory else { return }
        if Date().timeIntervalSince(lastUndoPush) > 0.7 {
            undoStack.append(previous)
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        lastUndoPush = Date()
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(settings)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        restore(next)
    }

    private func restore(_ value: EditSettings) {
        restoringHistory = true
        settings = value
        restoringHistory = false
        lastUndoPush = .distantPast
        if let selection, !exists(selection) { self.selection = nil }
    }

    private func exists(_ item: EditorSelection) -> Bool {
        switch item {
        case .zoom(let id): settings.zoomSegments.contains { $0.id == id }
        case .edit(let id): settings.timeEdits.contains { $0.id == id }
        case .camera(let id): settings.cameraLayouts.contains { $0.id == id }
        case .annotation(let id): settings.annotations.contains { $0.id == id }
        }
    }

    /// Previous/next interesting moment: flags and the starts of zooms, edits and annotations.
    func jump(forward: Bool) {
        var marks = flags + [0, duration]
        marks += settings.zoomSegments.map(\.start) + settings.timeEdits.map(\.start)
        marks += settings.annotations.map(\.start) + settings.cameraLayouts.map(\.start)
        let sorted = Set(marks).sorted()
        let target = forward
            ? sorted.first { $0 > currentTime + 0.05 } ?? duration
            : sorted.last { $0 < currentTime - 0.05 } ?? 0
        seek(to: target)
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: Playback

    func togglePlay() {
        if player.timeControlStatus != .paused {
            player.pause()
            return
        }
        let range = timeMap.editedRange(trimStart: settings.trimStart, trimEnd: trimEnd)
        if playerTime >= range.end - 0.05 || playerTime < range.start {
            seekEdited(range.start)
        }
        player.playImmediately(atRate: playbackRate)
    }

    /// Seeks to a recording time (times inside a cut jump to where the cut ends).
    func seek(to time: Double) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        seekEdited(timeMap.edited(atSource: clamped))
    }

    private func seekEdited(_ edited: Double) {
        playerTime = edited
        player.seek(to: CMTime(seconds: edited, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Zooms

    func regenerateAutoZoom() {
        settings.zoomSegments = ZoomPlanner.plan(clicks: cursor.clicks, duration: duration, scale: settings.autoZoomScale)
        selection = nil
    }

    func addZoomAtPlayhead() { addZoom(at: currentTime) }

    /// Adds a zoom in the free gap at `time`, or selects the zoom already there.
    func addZoom(at time: Double) {
        let scale = settings.autoZoomScale
        let result = SpanEditing.insert(settings.zoomSegments, at: time, duration: duration) { ZoomSegment(start: $0, end: $1, scale: scale) }
        select(result.selected.map(EditorSelection.zoom), updated: result.spans) { $0.zoomSegments = $1 }
    }

    var selectedZoom: ZoomSegment? {
        guard case .zoom(let id) = selection else { return nil }
        return settings.zoomSegments.first { $0.id == id }
    }

    func updateZoom(_ id: UUID, _ change: (inout ZoomSegment) -> Void) {
        guard let index = settings.zoomSegments.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.zoomSegments[index])
    }

    // MARK: Cuts and speed

    func addEdit(at time: Double, speed: Double) {
        let result = SpanEditing.insert(settings.timeEdits, at: time, length: 2, duration: duration) { TimeEdit(start: $0, end: $1, speed: speed) }
        select(result.selected.map(EditorSelection.edit), updated: result.spans) { $0.timeEdits = $1 }
    }

    var selectedEdit: TimeEdit? {
        guard case .edit(let id) = selection else { return nil }
        return settings.timeEdits.first { $0.id == id }
    }

    func updateEdit(_ id: UUID, _ change: (inout TimeEdit) -> Void) {
        guard let index = settings.timeEdits.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.timeEdits[index])
    }

    // MARK: Camera layouts

    func addCameraLayout(at time: Double, layout: CameraLayout) {
        let result = SpanEditing.insert(settings.cameraLayouts, at: time, length: 3, duration: duration) { CameraLayoutSegment(start: $0, end: $1, layout: layout) }
        select(result.selected.map(EditorSelection.camera), updated: result.spans) { $0.cameraLayouts = $1 }
    }

    var selectedCameraLayout: CameraLayoutSegment? {
        guard case .camera(let id) = selection else { return nil }
        return settings.cameraLayouts.first { $0.id == id }
    }

    func updateCameraLayout(_ id: UUID, _ change: (inout CameraLayoutSegment) -> Void) {
        guard let index = settings.cameraLayouts.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.cameraLayouts[index])
    }

    // MARK: Annotations

    func addAnnotation(at time: Double, kind: AnnotationKind) {
        let result = SpanEditing.insert(settings.annotations, at: time, length: 3, duration: duration, allowsOverlap: true) { start, end in
            var annotation = Annotation(start: start, end: end, kind: kind)
            switch kind {
            case .text:
                annotation.text = tr("annotation.default_text")
                annotation.color = RGBAColor(1, 1, 1)
                annotation.rect = CGRect(x: 0.3, y: 0.08, width: 0.4, height: 0.1)
            case .spotlight, .blur:
                annotation.color = RGBAColor(0, 0, 0)
            case .arrow, .box:
                break
            }
            return annotation
        }
        select(result.selected.map(EditorSelection.annotation), updated: result.spans) { $0.annotations = $1 }
    }

    var selectedAnnotation: Annotation? {
        guard case .annotation(let id) = selection else { return nil }
        return settings.annotations.first { $0.id == id }
    }

    func updateAnnotation(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let index = settings.annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.annotations[index])
    }

    // MARK: Generic span operations

    func move(_ item: EditorSelection, to start: Double) {
        switch item {
        case .zoom(let id): settings.zoomSegments = SpanEditing.move(settings.zoomSegments, id: id, to: start, duration: duration)
        case .edit(let id): settings.timeEdits = SpanEditing.move(settings.timeEdits, id: id, to: start, duration: duration)
        case .camera(let id): settings.cameraLayouts = SpanEditing.move(settings.cameraLayouts, id: id, to: start, duration: duration)
        case .annotation(let id): settings.annotations = SpanEditing.move(settings.annotations, id: id, to: start, duration: duration, allowsOverlap: true)
        }
    }

    func resize(_ item: EditorSelection, edge: SpanEditing.Edge, to time: Double) {
        switch item {
        case .zoom(let id): settings.zoomSegments = SpanEditing.resize(settings.zoomSegments, id: id, edge: edge, to: time, duration: duration)
        case .edit(let id): settings.timeEdits = SpanEditing.resize(settings.timeEdits, id: id, edge: edge, to: time, duration: duration)
        case .camera(let id): settings.cameraLayouts = SpanEditing.resize(settings.cameraLayouts, id: id, edge: edge, to: time, duration: duration)
        case .annotation(let id): settings.annotations = SpanEditing.resize(settings.annotations, id: id, edge: edge, to: time, duration: duration, allowsOverlap: true)
        }
    }

    func delete(_ item: EditorSelection) {
        switch item {
        case .zoom(let id): settings.zoomSegments.removeAll { $0.id == id }
        case .edit(let id): settings.timeEdits.removeAll { $0.id == id }
        case .camera(let id): settings.cameraLayouts.removeAll { $0.id == id }
        case .annotation(let id): settings.annotations.removeAll { $0.id == id }
        }
        if selection == item { selection = nil }
    }

    func deleteSelection() {
        if let selection { delete(selection) }
    }

    private func select<T>(_ item: EditorSelection?, updated spans: [T], apply: (inout EditSettings, [T]) -> Void) {
        var copy = settings
        apply(&copy, spans)
        if copy != settings { settings = copy }
        if let item {
            selection = item
        } else {
            message = tr("timeline.no_room")
        }
    }

    // MARK: Item actions (context menu and shortcuts)

    /// Free room for a new item in a lane at `time` (for the "+" hover preview).
    func freeSlot(in lane: EditorLane, at time: Double) -> (start: Double, end: Double)? {
        switch lane {
        case .zoom: SpanEditing.freeSlot(settings.zoomSegments, at: time, length: 2.5, duration: duration)
        case .edits: SpanEditing.freeSlot(settings.timeEdits, at: time, length: 2, duration: duration)
        case .camera: SpanEditing.freeSlot(settings.cameraLayouts, at: time, length: 3, duration: duration)
        case .annotations: SpanEditing.freeSlot(settings.annotations, at: time, length: 3, duration: duration, allowsOverlap: true)
        }
    }

    func add(in lane: EditorLane, at time: Double) {
        switch lane {
        case .zoom: addZoom(at: time)
        case .edits: addEdit(at: time, speed: 0)
        case .camera: addCameraLayout(at: time, layout: .fullscreen)
        case .annotations: addAnnotation(at: time, kind: .text)
        }
    }

    /// Splits the item at the playhead.
    func split(_ item: EditorSelection) {
        let t = currentTime
        func done<T>(_ result: (spans: [T], second: UUID)?, _ apply: (inout EditSettings, [T]) -> Void, _ wrap: (UUID) -> EditorSelection) {
            guard let result else {
                message = tr("item.split_hint")
                return
            }
            var copy = settings
            apply(&copy, result.spans)
            settings = copy
            selection = wrap(result.second)
        }
        switch item {
        case .zoom(let id): done(SpanEditing.split(settings.zoomSegments, id: id, at: t), { $0.zoomSegments = $1 }, EditorSelection.zoom)
        case .edit(let id): done(SpanEditing.split(settings.timeEdits, id: id, at: t), { $0.timeEdits = $1 }, EditorSelection.edit)
        case .camera(let id): done(SpanEditing.split(settings.cameraLayouts, id: id, at: t), { $0.cameraLayouts = $1 }, EditorSelection.camera)
        case .annotation(let id): done(SpanEditing.split(settings.annotations, id: id, at: t), { $0.annotations = $1 }, EditorSelection.annotation)
        }
    }

    /// Copy right after the original (or the nearest free gap).
    func duplicate(_ item: EditorSelection) {
        guard let clip = clipboardItem(for: item) else { return }
        paste(clip, at: end(of: item) ?? currentTime)
    }

    func toggleEnabled(_ item: EditorSelection) {
        guard case .zoom(let id) = item else { return }
        updateZoom(id) { $0.isEnabled.toggle() }
    }

    func copy(_ item: EditorSelection) {
        Self.clipboard = clipboardItem(for: item)
        message = tr("item.copied")
    }

    func cut(_ item: EditorSelection) {
        Self.clipboard = clipboardItem(for: item)
        delete(item)
    }

    /// Pastes the copied item at the playhead.
    func pasteAtPlayhead() {
        guard let clip = Self.clipboard else { return }
        paste(clip, at: currentTime)
    }

    func applyZoomLevelToAll(from id: UUID) {
        guard let level = settings.zoomSegments.first(where: { $0.id == id })?.scale else { return }
        for index in settings.zoomSegments.indices { settings.zoomSegments[index].scale = level }
    }

    private func paste(_ clip: ClipboardItem, at time: Double) {
        func done<T>(_ result: (spans: [T], id: UUID)?, _ apply: (inout EditSettings, [T]) -> Void, _ wrap: (UUID) -> EditorSelection) {
            guard let result else {
                message = tr("timeline.no_room")
                return
            }
            var copy = settings
            apply(&copy, result.spans)
            settings = copy
            selection = wrap(result.id)
        }
        switch clip {
        case .zoom(let span): done(SpanEditing.place(span, in: settings.zoomSegments, at: time, duration: duration), { $0.zoomSegments = $1 }, EditorSelection.zoom)
        case .edit(let span): done(SpanEditing.place(span, in: settings.timeEdits, at: time, duration: duration), { $0.timeEdits = $1 }, EditorSelection.edit)
        case .camera(let span): done(SpanEditing.place(span, in: settings.cameraLayouts, at: time, duration: duration), { $0.cameraLayouts = $1 }, EditorSelection.camera)
        case .annotation(let span): done(SpanEditing.place(span, in: settings.annotations, at: time, duration: duration, allowsOverlap: true), { $0.annotations = $1 }, EditorSelection.annotation)
        }
    }

    private func clipboardItem(for item: EditorSelection) -> ClipboardItem? {
        switch item {
        case .zoom(let id): settings.zoomSegments.first { $0.id == id }.map(ClipboardItem.zoom)
        case .edit(let id): settings.timeEdits.first { $0.id == id }.map(ClipboardItem.edit)
        case .camera(let id): settings.cameraLayouts.first { $0.id == id }.map(ClipboardItem.camera)
        case .annotation(let id): settings.annotations.first { $0.id == id }.map(ClipboardItem.annotation)
        }
    }

    private func end(of item: EditorSelection) -> Double? {
        switch item {
        case .zoom(let id): settings.zoomSegments.first { $0.id == id }?.end
        case .edit(let id): settings.timeEdits.first { $0.id == id }?.end
        case .camera(let id): settings.cameraLayouts.first { $0.id == id }?.end
        case .annotation(let id): settings.annotations.first { $0.id == id }?.end
        }
    }

    // MARK: Keyboard

    /// Editor shortcuts. Called for key presses in the editor window that are not text editing;
    /// returns true when the key was used.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            guard modifiers.isEmpty, selection != nil else { return false }
            deleteSelection()
            return true
        case 53: // escape
            guard selection != nil else { return false }
            selection = nil
            return true
        default:
            break
        }
        if modifiers.isEmpty {
            switch key {
            case " ": togglePlay()
            case "z": addZoomAtPlayhead()
            case "x": addEdit(at: currentTime, speed: 0)
            case "t": addAnnotation(at: currentTime, kind: .text)
            case "[": setTrimStartAtPlayhead()
            case "]": setTrimEndAtPlayhead()
            case "c": if let selection { split(selection) } else { return false }
            case "d": if let selection { toggleEnabled(selection) } else { return false }
            default: return false
            }
            return true
        }
        if modifiers == .command {
            switch key {
            case "z": undo()
            case "s": save()
            case "e": exportRequested = true
            case "d": if let selection { duplicate(selection) } else { return false }
            case "c": if let selection { copy(selection) } else { return false }
            case "x": if let selection { cut(selection) } else { return false }
            case "v": if Self.clipboard != nil { pasteAtPlayhead() } else { return false }
            default: return false
            }
            return true
        }
        if modifiers == [.command, .shift], key == "z" {
            redo()
            return true
        }
        return false
    }

    // MARK: Trim

    func setTrimStartAtPlayhead() {
        settings.trimStart = min(currentTime, max(trimEnd - 0.5, 0))
    }

    func setTrimEndAtPlayhead() {
        settings.trimEnd = max(currentTime, settings.trimStart + 0.5)
    }

    // MARK: Media

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = tr("audio.choose_music")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            settings.musicFile = try ProjectStore.importMusic(url, into: folder)
        } catch {
            message = error.localizedDescription
        }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.backgroundImagePath = url.path
        settings.backgroundKind = .image
    }

    /// Where the cursor was at `time` (normalized), to start a fixed focus somewhere sensible.
    func cursorPosition(at time: Double) -> CGPoint {
        CursorPath(samples: cursor.samples, smoothing: 0)?.position(at: time) ?? CGPoint(x: 0.5, y: 0.5)
    }

    /// Raw screen frame at a recording time (no background, zoom, camera or effects).
    func framePreview(at time: Double) async -> NSImage? {
        guard let base,
              let track = try? await base.composition.loadTrack(withTrackID: base.screenTrackID)
        else { return nil }
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: base.composition.duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = base.sourceSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        let generator = AVAssetImageGenerator(asset: base.composition)
        generator.videoComposition = composition
        generator.maximumSize = CGSize(width: 900, height: 560)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: Presets

    func reloadPresets() {
        presets = PresetStore.all()
    }

    func apply(_ preset: StylePreset) {
        settings = settings.applyingStyle(preset.settings)
    }

    func saveAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try PresetStore.save(name: trimmed, settings: settings)
            reloadPresets()
            message = tr("presets.saved", trimmed)
        } catch {
            message = error.localizedDescription
        }
    }

    func deletePreset(_ preset: StylePreset) {
        do {
            try PresetStore.delete(preset.name)
            if Preferences.shared.defaultPresetName == preset.name { Preferences.shared.defaultPresetName = nil }
            reloadPresets()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Saving

    func save() {
        saveTask?.cancel()
        data.settings = settings
        do {
            try ProjectStore.save(data, in: folder)
            isDirty = false
            Preferences.shared.lastProjectSettings = settings.styleOnly
        } catch {
            message = error.localizedDescription
        }
    }

    /// Drops unsaved edits (used when the user closes without saving).
    func discardChanges() {
        saveTask?.cancel()
        isDirty = false
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        rebuildTask?.cancel()
        if isDirty, Preferences.shared.autosave { save() }
    }

    // MARK: Export

    func export(options: ExportOptions, to url: URL) async {
        guard exportProgress == nil, let timeline else { return }
        player.pause()
        exportProgress = 0
        defer { exportProgress = nil }
        do {
            try await VideoExporter.export(
                timeline: timeline,
                cursor: cursor,
                settings: settings,
                sprite: sprite,
                keystrokes: keystrokes,
                timeRange: timeline.exportRange(for: settings),
                options: options,
                to: url
            ) { [weak self] value in
                Task { @MainActor in if self?.exportProgress != nil { self?.exportProgress = value } }
            }
            message = tr("editor.exported", url.lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            message = "\(tr("error.export_failed")) \(error.localizedDescription)"
        }
    }

    // MARK: Rebuilding

    private func settingsChanged() {
        isDirty = true
        if Preferences.shared.autosave {
            saveTask?.cancel()
            saveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.save()
            }
        }
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    /// Re-applies timing/audio effects when they changed (new player item), otherwise only the look.
    private func rebuild() async {
        guard let base else { return }
        if builtStructure != settings.structureKey || timeline == nil {
            let structure = settings.structureKey
            do {
                let built = try await base.applying(settings, cursor: cursor, folder: folder)
                guard structure == settings.structureKey else { return } // a newer change is coming
                timeline = built
                builtStructure = structure
                finalDuration = built.timeMap.totalDuration
                let wasPlaying = player.timeControlStatus != .paused
                let item = AVPlayerItem(asset: built.composition)
                item.audioMix = built.audioMix
                item.audioTimePitchAlgorithm = .spectral
                configure(item)
                player.replaceCurrentItem(with: item)
                seek(to: currentTime)
                if wasPlaying { player.play() }
            } catch {
                message = error.localizedDescription
            }
        } else if let item = player.currentItem {
            configure(item)
            if player.timeControlStatus == .paused { seekEdited(playerTime) } // refresh the still frame
        }
    }

    private func configure(_ item: AVPlayerItem) {
        guard let timeline else { return }
        item.videoComposition = CompositionBuilder.make(
            timeline: timeline,
            cursor: cursor,
            settings: settings,
            sprite: sprite,
            keystrokes: keystrokes,
            outputScale: CompositionBuilder.previewScale(sourceSize: sourceSize, settings: settings, maxDimension: previewQuality.maxDimension)
        )
        let range = timeline.timeMap.editedRange(trimStart: settings.trimStart, trimEnd: trimEnd)
        item.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 600)
    }
}
