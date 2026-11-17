import AVFoundation
import AppKit
import SwiftUI

// MARK: - HUD

/// Short transient message near the top of the current screen.
@MainActor
enum Hud {
    private static var panel: FloatingPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, seconds: Double = 2.2) {
        hideTask?.cancel()
        let screen = NSScreen.current ?? NSScreen.screens[0]
        let size = NSSize(width: 520, height: 64)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24, width: size.width, height: size.height)
        let panel = panel ?? FloatingPanel(frame: frame, level: .statusBar, acceptsKey: false, clickThrough: true)
        panel.setFrame(frame, display: true)
        panel.host(
            Text(text)
                .font(.body.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        panel.orderFrontRegardless()
        self.panel = panel
        hideTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

// MARK: - Countdown

@MainActor
final class CountdownState: ObservableObject {
    @Published var value: Int
    var cancelled = false

    init(value: Int) { self.value = value }
}

@MainActor
enum Countdown {
    /// Returns false when cancelled with Esc.
    static func run(seconds: Int, on screen: NSScreen) async -> Bool {
        guard seconds > 0 else { return true }
        let state = CountdownState(value: seconds)
        let size: CGFloat = 220
        let panel = FloatingPanel(
            frame: NSRect(x: screen.frame.midX - size / 2, y: screen.frame.midY - size / 2, width: size, height: size),
            level: .statusBar
        )
        panel.onCancel = { state.cancelled = true }
        panel.host(CountdownView(state: state))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        for value in stride(from: seconds, to: 0, by: -1) {
            state.value = value
            try? await Task.sleep(for: .seconds(1))
            if state.cancelled { break }
        }
        panel.orderOut(nil)
        panel.contentView = nil
        return !state.cancelled
    }
}

private struct CountdownView: View {
    @ObservedObject var state: CountdownState

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.7))
            Text("\(state.value)")
                .font(.system(size: 110, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.snappy, value: state.value)
            Text(tr("countdown.esc"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .offset(y: 78)
        }
        .padding(6)
    }
}

// MARK: - Recorded area highlight

/// Dims everything outside the recorded area and outlines it. Click-through, never captured.
@MainActor
final class HighlightOverlay {
    private var panels: [FloatingPanel] = []

    /// `hole` in CG global coordinates.
    func show(hole: CGRect, dim: Bool) {
        hide()
        for screen in NSScreen.screens {
            let local = hole.offsetBy(dx: -screen.cgFrame.minX, dy: -screen.cgFrame.minY)
            guard dim || screen.cgFrame.intersects(hole) else { continue }
            let panel = FloatingPanel(frame: screen.frame, level: .statusBar, acceptsKey: false, clickThrough: true)
            panel.host(HoleView(hole: local, dim: dim))
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }
}

private struct HoleView: View {
    let hole: CGRect
    let dim: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if dim {
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        path.addRect(hole)
                    }
                    .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                }
                Rectangle()
                    .strokeBorder(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                    .frame(width: hole.width + 6, height: hole.height + 6)
                    .offset(x: hole.minX - 3, y: hole.minY - 3)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Hide desktop icons

/// Covers desktop icons with the wallpaper while recording. Unlike our other windows these
/// are captured (passed as included windows), so the recording shows a clean desktop.
/// Finder settings are never touched.
@MainActor
final class DesktopCover {
    private var windows: [NSWindow] = []

    var windowIDs: [CGWindowID] { windows.map { CGWindowID($0.windowNumber) } }

    func show() {
        hide()
        for screen in NSScreen.screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  let image = NSImage(contentsOf: url)
            else { continue }
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contents = image
            view.layer?.contentsGravity = .resizeAspectFill
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

// MARK: - Recording widget

@MainActor
final class RecordingWidgetController {
    private var panel: FloatingPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show(on screen: NSScreen?) {
        let screen = screen ?? NSScreen.current ?? NSScreen.screens[0]
        let size = NSSize(width: 430, height: 60)
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 20, width: size.width, height: size.height)
        let panel = panel ?? FloatingPanel(frame: frame, level: .statusBar, acceptsKey: false)
        panel.isMovableByWindowBackground = true
        panel.host(RecordingWidgetView(recorder: AppModel.shared.recorder))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle(on screen: NSScreen?) {
        isVisible ? hide() : show(on: screen)
    }
}

private struct RecordingWidgetView: View {
    @ObservedObject var recorder: ScreenRecorder
    @State private var flags = 0

    var body: some View {
        let app = AppModel.shared
        HStack(spacing: 14) {
            Circle()
                .fill(recorder.state == .paused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(formatClock(recorder.elapsed))
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .frame(width: 70, alignment: .leading)
            }
            Divider().frame(height: 26)
            WidgetButton(icon: recorder.state == .paused ? "play.fill" : "pause.fill",
                         help: recorder.state == .paused ? tr("menu.resume") : tr("menu.pause")) {
                Task { await app.togglePause() }
            }
            WidgetButton(icon: flags > 0 ? "flag.fill" : "flag", help: tr("menu.flag")) {
                app.addFlag()
                flags += 1
            }
            WidgetButton(icon: "arrow.counterclockwise", help: tr("menu.restart")) {
                Task { await app.restartRecording() }
            }
            WidgetButton(icon: "trash", help: tr("menu.cancel_recording")) {
                Task { await app.cancelRecording() }
            }
            Button {
                Task { await app.stopRecording() }
            } label: {
                Label(tr("widget.finish"), systemImage: "stop.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help(tr("menu.finish"))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.1).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

private struct WidgetButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

func formatClock(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Speaker notes / prompter

@MainActor
final class PrompterState: ObservableObject {
    @Published var prompting = false
    @Published var running = false {
        didSet { running ? startTimer() : stopTimer() }
    }
    @Published var offset: CGFloat = 0
    private var timer: Timer?

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.offset += CGFloat(Preferences.shared.prompterSpeed) / 60
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// Floating notes you can read while recording (never captured), with an auto-scrolling prompter.
@MainActor
final class SpeakerNotesController: NSObject, NSWindowDelegate {
    let state = PrompterState()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        if panel == nil {
            let screen = NSScreen.current ?? NSScreen.screens[0]
            let size = NSSize(width: 480, height: 300)
            let panel = NSPanel(
                contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 20, width: size.width, height: size.height),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: LocalizedRoot { SpeakerNotesView(state: self.state) })
            self.panel = panel
        }
        panel?.title = tr("notes.title")
        panel?.orderFrontRegardless()
    }

    func hide() {
        state.running = false
        panel?.orderOut(nil)
    }

    func toggle() { isVisible ? hide() : show() }

    func togglePrompter() {
        if !isVisible { show() }
        state.prompting = true
        state.running.toggle()
    }

    func windowWillClose(_ notification: Notification) {
        state.running = false
    }
}

private struct SpeakerNotesView: View {
    @ObservedObject var state: PrompterState
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $state.prompting) {
                    Text(tr("notes.edit")).tag(false)
                    Text(tr("notes.prompter")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                if state.prompting {
                    Button { state.offset = 0 } label: { Image(systemName: "backward.end.fill") }
                        .help(tr("notes.restart"))
                    Button { state.running.toggle() } label: { Image(systemName: state.running ? "pause.fill" : "play.fill") }
                        .help(tr("shortcut.prompter"))
                    Slider(value: $prefs.prompterSpeed, in: 10...150).frame(width: 90)
                        .help(tr("notes.speed"))
                }
            }
            if state.prompting {
                GeometryReader { geometry in
                    Text(prefs.speakerNotes.isEmpty ? tr("notes.empty") : prefs.speakerNotes)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: geometry.size.width - 24, alignment: .leading)
                        .padding(.horizontal, 12)
                        .offset(y: geometry.size.height / 3 - state.offset)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .clipped()
                }
                .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
            } else {
                TextEditor(text: $prefs.speakerNotes)
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
    }
}

// MARK: - Quick export widget

@MainActor
final class QuickExportModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case exporting(Double)
        case exported(URL, copied: Bool)
        case failed(String)
    }

    let folder: URL
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var duration: Double = 0
    @Published var phase: Phase = .ready
    @Published var askKeep = false

    init(folder: URL) { self.folder = folder }

    func load() async {
        guard let data = try? ProjectStore.load(from: folder) else { return }
        let first = folder.appending(path: data.screenFiles[0])
        let asset = AVURLAsset(url: first)
        var total = 0.0
        for file in data.screenFiles {
            total += (try? await AVURLAsset(url: folder.appending(path: file)).load(.duration).seconds) ?? 0
        }
        duration = total
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 640, height: 400)
        generator.appliesPreferredTrackTransform = true
        if let image = try? await generator.image(at: CMTime(seconds: min(1, total / 2), preferredTimescale: 600)).image {
            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    func export(toClipboard: Bool) async {
        let destination: URL?
        if toClipboard {
            destination = nil
        } else {
            guard let chosen = AppModel.shared.chooseExportURL(name: folder.lastPathComponent, format: Preferences.shared.quickExport.format) else { return }
            destination = chosen
        }
        phase = .exporting(0)
        let url = await AppModel.shared.quickExport(folder: folder, to: destination, copyToClipboard: toClipboard) { [weak self] value in
            Task { @MainActor in
                if case .exporting = self?.phase { self?.phase = .exporting(value) }
            }
        }
        if let url {
            phase = .exported(url, copied: toClipboard)
            askKeep = !Preferences.shared.alwaysSaveProject
        } else {
            phase = .failed(tr("error.export_failed"))
        }
    }
}

@MainActor
final class QuickExportWidgetController {
    private var panel: FloatingPanel?

    func show(folder: URL) {
        let screen = NSScreen.current ?? NSScreen.screens[0]
        let size = NSSize(width: 380, height: 330)
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 24, y: screen.visibleFrame.minY + 24, width: size.width, height: size.height)
        let panel = panel ?? FloatingPanel(frame: frame, level: .floating)
        panel.isMovableByWindowBackground = true
        let model = QuickExportModel(folder: folder)
        panel.onCancel = { [weak self] in self?.hide() }
        panel.host(QuickExportWidgetView(model: model, close: { [weak self] in self?.hide() }))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        Task { await model.load() }
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

private struct QuickExportWidgetView: View {
    @ObservedObject var model: QuickExportModel
    let close: () -> Void

    var body: some View {
        let app = AppModel.shared
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("quick.title")).font(.headline)
                Spacer()
                Text(formatClock(model.duration)).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.4))
                if let thumbnail = model.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            switch model.phase {
            case .exporting(let value):
                ProgressView(value: value) { Text(tr("hud.exporting")).font(.caption) }
            case .exported(let url, let copied):
                if model.askKeep {
                    Text(copied ? tr("quick.copied_keep") : tr("quick.saved_keep")).font(.callout)
                    HStack {
                        Button(tr("quick.keep")) { model.askKeep = false; close() }
                        Button(tr("quick.delete_project"), role: .destructive) {
                            app.deleteProject(model.folder, confirm: false)
                            close()
                        }
                    }
                } else {
                    Label(copied ? tr("hud.copied") : tr("quick.saved"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    HStack {
                        Button(tr("quick.show_file")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button(tr("close"), action: close)
                    }
                }
            case .ready, .failed:
                if case .failed(let message) = model.phase {
                    Text(message).foregroundStyle(.red).font(.caption)
                }
                HStack {
                    Button { Task { await model.export(toClipboard: true) } } label: {
                        Label(tr("quick.export_copy"), systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.recordAccent)
                    Button { Task { await model.export(toClipboard: false) } } label: {
                        Label(tr("quick.save_file"), systemImage: "square.and.arrow.down")
                    }
                }
                HStack {
                    Button { app.open(model.folder); close() } label: {
                        Label(tr("quick.open_editor"), systemImage: "slider.horizontal.3")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        if app.deleteProject(model.folder, confirm: true) { close() }
                    } label: {
                        Label(tr("delete"), systemImage: "trash")
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
    }
}
