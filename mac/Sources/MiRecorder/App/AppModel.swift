import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Coordinates recording, windows, menus, hot keys and exports.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let prefs = Preferences.shared
    let recorder = ScreenRecorder()
    let mic = MicMonitor()
    let windows = WindowManager()
    let notes = SpeakerNotesController()

    @Published private(set) var cameras: [CameraRecorder.Device] = []
    @Published private(set) var microphones: [AudioDevice] = []
    @Published private(set) var mobileDevices: [CameraRecorder.Device] = []
    @Published private(set) var failedShortcuts: Set<ShortcutAction> = []

    private let toolbar = RecordingToolbarController()
    private let projectsOverlay = ProjectsOverlayController()
    @Published private(set) var projectsOverlayVisible = false
    private let widget = RecordingWidgetController()
    private let highlight = HighlightOverlay()
    private let desktopCover = DesktopCover()
    private let bubble = CameraBubble()
    private let quickWidget = QuickExportWidgetController()
    private var lastTarget: CaptureTarget?
    private var lastArea: CGRect?
    /// True from opening a target picker until the recording starts or is abandoned.
    private var preparing = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    // MARK: Lifecycle

    func launch() {
        recorder.onUnexpectedStop = { [weak self] captured in
            Task { await self?.finish(captured) }
        }
        windows.onChange = { [weak self] in self?.updateDockPolicy() }

        // @Published emits before the value is stored; react on the next run loop turn.
        func onChange<T>(_ publisher: Published<T>.Publisher, _ action: @escaping (AppModel) -> Void) {
            publisher.dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in if let self { action(self) } }
                .store(in: &cancellables)
        }
        onChange(prefs.$shortcuts) { $0.registerHotKeys() }
        onChange(prefs.$showInDock) { $0.updateDockPolicy() }
        onChange(prefs.$hideDockWhileRecording) { $0.updateDockPolicy() }
        onChange(prefs.$cameraID) { model in Task { await model.updateCameraPreview() } }
        onChange(prefs.$cameraResolution) { model in Task { await model.updateCameraPreview() } }
        onChange(prefs.$microphoneID) { model in Task { await model.updateMicMonitor() } }
        onChange(prefs.$language) { $0.windows.refreshTitles() }
        recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDockPolicy() }
            .store(in: &cancellables)

        MobileDevices.enable()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshDevices() }
                .store(in: &cancellables)
        }
        refreshDevices()
        registerHotKeys()
        updateDockPolicy()
        // `--open <project folder>` opens a project directly (handy for scripts and development).
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--open"), index + 1 < arguments.count {
            open(URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        } else {
            showToolbar()
        }
    }

    func refreshDevices() {
        mobileDevices = MobileDevices.connected()
        // iPhones/iPads are listed as capture devices too; keep them out of the camera menu.
        cameras = CameraRecorder.availableDevices().filter { camera in !mobileDevices.contains { $0.id == camera.id } }
        microphones = AudioDevice.microphones()
        if let id = prefs.cameraID, !cameras.contains(where: { $0.id == id }) { prefs.cameraID = nil }
        if let id = prefs.microphoneID, !microphones.contains(where: { $0.id == id }) { prefs.microphoneID = nil }
    }

    func registerHotKeys() {
        var bindings: [(KeyCombo, () -> Void)] = []
        var actions: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            guard let combo = prefs.shortcut(for: action) else { continue }
            actions.append(action)
            bindings.append((combo, { [weak self] in self?.perform(action) }))
        }
        let failed = HotKeyCenter.shared.register(bindings)
        failedShortcuts = Set(actions.filter { action in failed.contains { $0 == prefs.shortcut(for: action) } })
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .newRecording: newRecording()
        case .pauseResume: Task { await togglePause() }
        case .restart: Task { await restartRecording() }
        case .flag: addFlag()
        case .recordDisplay: Task { await beginRecording(.display) }
        case .recordWindow: Task { await beginRecording(.window) }
        case .recordArea: Task { await beginRecording(.area) }
        case .speakerNotes: notes.toggle()
        case .prompter: notes.togglePrompter()
        case .toggleControls: toggleControls()
        }
    }

    // MARK: Toolbar and camera preview

    /// "Start new recording / Finish recording".
    func newRecording() {
        if recorder.isActive {
            Task { await stopRecording() }
        } else if recorder.state == .idle, !preparing {
            showToolbar()
        }
    }

    func showToolbar() {
        refreshDevices()
        toolbar.show()
        Task {
            await updateCameraPreview()
            await updateMicMonitor()
        }
    }

    /// Folder button: blurred panel with recent projects behind the toolbar.
    func toggleProjectsOverlay() {
        projectsOverlayVisible ? hideProjectsOverlay() : showProjectsOverlay()
    }

    func showProjectsOverlay() {
        guard let screen = toolbar.screen ?? NSScreen.current else { return }
        projectsOverlay.show(on: screen)
        projectsOverlayVisible = true
        toolbar.bringToFront()
        bubble.bringToFront()
    }

    func hideProjectsOverlay() {
        projectsOverlay.hide()
        projectsOverlayVisible = false
    }

    func closeToolbar() {
        hideProjectsOverlay()
        toolbar.hide()
        mic.stop()
        Task { await updateCameraPreview() }
    }

    private var needsCamera: Bool { toolbar.isVisible || preparing || recorder.isActive }

    func updateCameraPreview() async {
        guard needsCamera, let id = prefs.cameraID else {
            bubble.hide()
            if !recorder.isActive { await recorder.camera.stop() }
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            prefs.cameraID = nil
            Hud.show(tr("error.camera_permission"), seconds: 4)
            return
        }
        do {
            try await recorder.camera.start(deviceID: id, resolution: prefs.cameraResolution)
            if needsCamera, prefs.cameraID != nil { bubble.show(session: recorder.camera.session) }
        } catch {
            prefs.cameraID = nil
            Hud.show(error.localizedDescription, seconds: 4)
        }
    }

    func updateMicMonitor() async {
        guard toolbar.isVisible, let id = prefs.microphoneID else {
            mic.stop()
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            prefs.microphoneID = nil
            Hud.show(tr("error.mic_permission"), seconds: 4)
            return
        }
        mic.start(deviceID: id)
    }

    // MARK: Recording

    func beginRecording(_ mode: CaptureMode) async {
        guard recorder.state == .idle, !preparing else { return }
        preparing = true
        hideProjectsOverlay()
        toolbar.hide()
        mic.stop()
        windows.hideAll()

        let target: CaptureTarget?
        switch mode {
        case .display:
            target = await TargetPicker.pickDisplay().map(CaptureTarget.display)
        case .window:
            target = await TargetPicker.pickWindow().map(CaptureTarget.window)
        case .area:
            let screen = NSScreen.current ?? NSScreen.screens[0]
            if let rect = await RegionSelector.select(on: screen, initial: lastArea), let id = screen.displayID {
                lastArea = rect
                target = .area(display: id, rect: rect)
            } else {
                target = nil
            }
        }
        guard let target else {
            preparing = false
            windows.restoreHidden()
            showToolbar()
            return
        }
        await startRecording(target)
    }

    /// Records a USB-connected iPhone / iPad (no picker needed).
    func beginDeviceRecording(_ id: String) async {
        guard recorder.state == .idle, !preparing else { return }
        preparing = true
        hideProjectsOverlay()
        toolbar.hide()
        mic.stop()
        windows.hideAll()
        await startRecording(.device(id))
    }

    func showDeviceHelp() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = tr("device.help.title")
        alert.informativeText = tr("device.help.message")
        alert.addButton(withTitle: tr("close"))
        alert.runModal()
    }

    private func startRecording(_ target: CaptureTarget) async {
        preparing = true
        defer { preparing = false }
        lastTarget = target
        let screen = screen(for: target)

        if prefs.hideDesktopIcons, !isWindow(target) {
            desktopCover.show()
            try? await Task.sleep(for: .milliseconds(200)) // let the window server publish the cover
        }
        if prefs.countdown > 0, let screen {
            guard await Countdown.run(seconds: prefs.countdown, on: screen) else {
                abandonStart()
                return
            }
        }

        var cameraReady = false
        if prefs.cameraID != nil {
            await updateCameraPreview()
            cameraReady = recorder.camera.session.isRunning
        }
        if prefs.recordKeystrokes { Keystrokes.ensurePermission() }
        await recorder.start(target: target, options: .init(
            systemAudio: prefs.captureSystemAudio,
            microphoneID: prefs.microphoneID,
            cameraEnabled: cameraReady,
            includedWindowIDs: desktopCover.windowIDs,
            recordKeystrokes: prefs.recordKeystrokes
        ))
        guard recorder.isActive else {
            abandonStart()
            if let message = recorder.errorMessage { Hud.show(message, seconds: 5) }
            return
        }

        if prefs.highlightRecordedArea, let hole = hole(for: target) {
            highlight.show(hole: hole, dim: true)
        }
        if prefs.showRecordingWidget { widget.show(on: screen) }
        if prefs.showSpeakerNotes { notes.show() }
        updateDockPolicy()
    }

    private func abandonStart() {
        tearDownRecordingUI()
        windows.restoreHidden()
        showToolbar()
    }

    func stopRecording() async {
        guard recorder.isActive else { return }
        let captured = await recorder.stop()
        await finish(captured)
    }

    func cancelRecording() async {
        guard recorder.isActive else { return }
        await recorder.cancel()
        tearDownRecordingUI()
        await recorder.camera.stop()
        windows.restoreHidden()
        Hud.show(tr("hud.cancelled"))
    }

    func restartRecording() async {
        guard recorder.isActive, let target = lastTarget else { return }
        await recorder.cancel()
        tearDownRecordingUI()
        await startRecording(target)
    }

    func togglePause() async {
        switch recorder.state {
        case .recording: await recorder.pause()
        case .paused: await recorder.resume()
        default: break
        }
    }

    func addFlag() {
        guard recorder.state == .recording else { return }
        recorder.addFlag()
        Hud.show(tr("hud.flag"), seconds: 1)
    }

    func toggleControls() {
        guard recorder.isActive else { return }
        widget.toggle(on: lastTarget.flatMap(screen(for:)))
    }

    private func finish(_ captured: CapturedRecording?) async {
        tearDownRecordingUI()
        bubble.hide()
        await recorder.camera.stop()
        windows.restoreHidden()
        updateDockPolicy()
        guard let captured else {
            if let message = recorder.errorMessage { Hud.show(message, seconds: 5) }
            return
        }
        do {
            let folder = try saveProject(captured)
            await handleAfterRecording(folder)
        } catch {
            Hud.show(error.localizedDescription, seconds: 5)
        }
    }

    private func tearDownRecordingUI() {
        widget.hide()
        highlight.hide()
        desktopCover.hide()
        notes.hide()
    }

    private func saveProject(_ captured: CapturedRecording) throws -> URL {
        var settings = baseSettings()
        if prefs.autoZoom {
            settings.zoomSegments = ZoomPlanner.plan(clicks: captured.cursor.clicks, duration: captured.duration, scale: settings.autoZoomScale)
        }
        let data = ProjectData(
            createdAt: Date(),
            cursor: captured.cursor,
            settings: settings,
            camera: captured.camera,
            segments: captured.segmentFiles,
            flags: captured.flags,
            keystrokes: captured.keystrokes
        )
        try ProjectStore.save(data, in: captured.folder)
        return captured.folder
    }

    /// Look for new projects: default preset, else last edited project's look, else defaults.
    func baseSettings() -> EditSettings {
        var settings = EditSettings()
        if let name = prefs.defaultPresetName, let preset = PresetStore.load(name) {
            settings = preset.settings.styleOnly
        } else if prefs.useLastProjectSettings, let last = prefs.lastProjectSettings {
            settings = last.styleOnly
        }
        // The video keeps the shape you saw in the live bubble.
        settings.cameraShape = prefs.cameraBubbleShape
        settings.cameraBorderColor = prefs.cameraBorderColor
        return settings
    }

    private func handleAfterRecording(_ folder: URL) async {
        switch prefs.afterRecording {
        case .createProject:
            if prefs.showQuickExportWidget {
                quickWidget.show(folder: folder)
            } else {
                open(folder)
            }
        case .exportCopy:
            Hud.show(tr("hud.exporting"), seconds: 60)
            _ = await quickExport(folder: folder, to: nil, copyToClipboard: true)
        case .exportSave:
            guard let url = chooseExportURL(name: folder.lastPathComponent, format: prefs.quickExport.format) else {
                open(folder)
                return
            }
            Hud.show(tr("hud.exporting"), seconds: 60)
            if let saved = await quickExport(folder: folder, to: url, copyToClipboard: false) {
                Hud.show(tr("quick.saved"))
                NSWorkspace.shared.activateFileViewerSelecting([saved])
            }
        }
    }

    // MARK: Export

    /// Exports a project with the Quick export settings. `to: nil` writes into the Exports folder.
    func quickExport(
        folder: URL,
        to destination: URL?,
        copyToClipboard: Bool,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async -> URL? {
        do {
            let data = try ProjectStore.load(from: folder)
            Wallpaper.refresh()
            let timeline = try await ProjectStore.editedTimeline(for: folder, data: data)
            let options = prefs.quickExport
            let url = destination ?? ProjectStore.exportsDirectory.appending(path: "\(folder.lastPathComponent).\(options.format.fileExtension)")
            try await VideoExporter.export(
                timeline: timeline,
                cursor: data.cursor,
                settings: data.settings,
                sprite: CursorSprite.systemArrow(),
                keystrokes: data.keystrokes ?? [],
                timeRange: timeline.exportRange(for: data.settings),
                options: options,
                to: url,
                progress: progress
            )
            if copyToClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                Hud.show(tr("hud.copied"))
            }
            return url
        } catch {
            Hud.show("\(tr("error.export_failed")) \(error.localizedDescription)", seconds: 5)
            return nil
        }
    }

    func chooseExportURL(name: String, format: ExportOptions.Format) -> URL? {
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .gif ? .gif : (format == .prores ? .quickTimeMovie : .mpeg4Movie)]
        panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.level = .modalPanel
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Projects and windows

    func showProjects() { windows.showProjects() }

    func showSettings(_ tab: SettingsTab) { windows.showSettings(tab) }

    func open(_ folder: URL) {
        do {
            try windows.openEditor(folder)
        } catch {
            Hud.show("\(tr("error.open_project")) \(error.localizedDescription)", seconds: 5)
        }
    }

    func openProjectPanel() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = ProjectStore.root
        panel.message = tr("open.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if ProjectStore.isProject(url) {
            open(url)
        } else {
            Hud.show(tr("error.not_a_project"), seconds: 4)
        }
    }

    func openLastProject() {
        guard let last = ProjectStore.recentProjects(limit: 1).first else {
            Hud.show(tr("projects.empty"))
            return
        }
        open(last)
    }

    /// Moves a project to the Trash. Returns true when deleted.
    @discardableResult
    func deleteProject(_ folder: URL, confirm: Bool) -> Bool {
        if confirm {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = tr("delete.title")
            alert.informativeText = tr("delete.message", folder.lastPathComponent)
            alert.addButton(withTitle: tr("delete"))
            alert.addButton(withTitle: tr("cancel"))
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        windows.closeEditor(for: folder)
        do {
            try ProjectStore.delete(folder)
            objectWillChange.send()
            return true
        } catch {
            Hud.show(error.localizedDescription, seconds: 4)
            return false
        }
    }

    func updateDockPolicy() {
        let hiddenForRecording = recorder.isActive && prefs.hideDockWhileRecording
        let regular = !hiddenForRecording && (prefs.showInDock || windows.hasVisibleWindows)
        let policy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    // MARK: Geometry

    /// Targets where covering the desktop icons makes no sense.
    private func isWindow(_ target: CaptureTarget) -> Bool {
        switch target {
        case .window, .device: return true
        case .display, .area: return false
        }
    }

    private func screen(for target: CaptureTarget) -> NSScreen? {
        switch target {
        case .display(let id), .area(let id, _):
            return NSScreen.screen(for: id)
        case .window(let id):
            guard let frame = WindowCandidate.onScreen().first(where: { $0.id == id })?.frame else { return NSScreen.current }
            return NSScreen.screens.first { $0.cgFrame.intersects(frame) } ?? NSScreen.current
        case .device:
            return NSScreen.current
        }
    }

    /// Recorded rectangle in CG global coordinates (nil for a whole display).
    private func hole(for target: CaptureTarget) -> CGRect? {
        switch target {
        case .display, .device:
            return nil
        case .area(let id, let rect):
            guard let screen = NSScreen.screen(for: id) else { return nil }
            return rect.offsetBy(dx: screen.cgFrame.minX, dy: screen.cgFrame.minY)
        case .window(let id):
            return WindowCandidate.onScreen().first { $0.id == id }?.frame
        }
    }
}
