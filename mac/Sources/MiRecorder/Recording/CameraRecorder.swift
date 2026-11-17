import AVFoundation
import AppKit

/// Owns the camera capture session: live preview for the bubble and recording to camera.mov.
@MainActor
final class CameraRecorder: NSObject {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
    }

    enum CameraError: LocalizedError {
        case noCamera
        case unusable

        var errorDescription: String? {
            switch self {
            case .noCamera: tr("error.no_camera")
            case .unusable: tr("error.camera_unusable")
            }
        }
    }

    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "mirecorder.camera-session")
    private var configuredDeviceID: String?
    private var configuredResolution: CameraResolution?
    private var recordingURL: URL?
    private var startUptime: TimeInterval?
    private var didFinish = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    static func availableDevices() -> [Device] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start(deviceID: String?, resolution: CameraResolution) async throws {
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }
        if configuredDeviceID != device.uniqueID || configuredResolution != resolution {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CameraError.unusable
            }
            session.addInput(input)
            if !session.outputs.contains(output), session.canAddOutput(output) {
                session.addOutput(output)
            }
            // Use the requested maximum, falling back to what the camera supports.
            let presets: [AVCaptureSession.Preset] = switch resolution {
            case .p4k: [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
            case .p1080: [.hd1920x1080, .hd1280x720, .high]
            case .p720: [.hd1280x720, .high]
            }
            if let preset = presets.first(where: session.canSetSessionPreset) {
                session.sessionPreset = preset
            }
            session.commitConfiguration()
            configuredDeviceID = device.uniqueID
            configuredResolution = resolution
        }
        if !session.isRunning {
            await onSessionQueue { $0.startRunning() }
        }
    }

    func stop() async {
        if output.isRecording { _ = await stopRecording() }
        if session.isRunning {
            await onSessionQueue { $0.stopRunning() }
        }
    }

    func startRecording(to url: URL) {
        guard session.isRunning, !output.isRecording else { return }
        recordingURL = url
        startUptime = nil
        didFinish = false
        output.startRecording(to: url, recordingDelegate: self)
    }

    func pause() {
        if output.isRecording, !output.isRecordingPaused { output.pauseRecording() }
    }

    func resume() {
        if output.isRecordingPaused { output.resumeRecording() }
    }

    /// Returns the clip and the uptime at which its first frame was captured.
    func stopRecording() async -> (url: URL, startUptime: TimeInterval)? {
        guard let url = recordingURL else { return nil }
        recordingURL = nil
        if output.isRecording {
            output.stopRecording()
        }
        if !didFinish {
            await withCheckedContinuation { finishContinuation = $0 }
        }
        guard let startUptime, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (url, startUptime)
    }

    private func onSessionQueue(_ work: @escaping (AVCaptureSession) -> Void) async {
        let session = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                work(session)
                continuation.resume()
            }
        }
    }

    private func finished() {
        didFinish = true
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in self.startUptime = now }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.finished() }
    }
}

/// Live bubble sizes (diameter in points).
enum CameraBubbleSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large, xlarge

    var id: String { rawValue }
    var title: String { tr("bubble.size.\(rawValue)") }
    var points: CGFloat {
        switch self {
        case .small: 140
        case .medium: 200
        case .large: 280
        case .xlarge: 380
        }
    }
}

/// Floating preview so you can see yourself while recording. Drag to move; right-click for size and shape.
/// It belongs to this app, which is excluded from the screen capture, so it never appears twice.
@MainActor
final class CameraBubble: NSObject {
    private var panel: NSPanel?
    private var content: NSView?
    private let prefs = Preferences.shared

    func show(session: AVCaptureSession) {
        if panel == nil {
            let size = prefs.cameraBubbleSize.points
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            let panel = NSPanel(
                contentRect: NSRect(x: visible.maxX - size - 32, y: visible.minY + 32, width: size, height: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            view.wantsLayer = true
            view.autoresizingMask = [.width, .height]
            view.layer?.masksToBounds = true
            view.layer?.borderWidth = 1.5
            view.toolTip = tr("bubble.hint")
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(preview)
            view.menu = makeMenu()
            panel.contentView = view
            self.panel = panel
            content = view
            applyShape()
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func bringToFront() {
        if panel?.isVisible == true { panel?.orderFrontRegardless() }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("bubble.size"), action: nil, keyEquivalent: "").isEnabled = false
        for size in CameraBubbleSize.allCases {
            let item = NSMenuItem(title: size.title, action: #selector(pickSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = size == prefs.cameraBubbleSize ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("camera.shape"), action: nil, keyEquivalent: "").isEnabled = false
        for shape in CameraShape.allCases {
            let item = NSMenuItem(title: shape.title, action: #selector(pickShape(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shape.rawValue
            item.image = NSImage(systemSymbolName: shape.icon, accessibilityDescription: nil)
            item.state = shape == prefs.cameraBubbleShape ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("camera.border_color"), action: nil, keyEquivalent: "").isEnabled = false
        for preset in RGBAColor.borderPresets {
            let item = NSMenuItem(title: tr("camera.border.\(preset.key)"), action: #selector(pickBorder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.key
            item.image = Self.swatch(preset.color)
            item.state = preset.color == prefs.cameraBorderColor ? .on : .off
            menu.addItem(item)
        }
        let custom = NSMenuItem(title: tr("camera.border.custom"), action: #selector(pickCustomBorder), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        return menu
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = CameraBubbleSize(rawValue: raw),
              let panel else { return }
        prefs.cameraBubbleSize = size
        // Grow or shrink around the bubble's center, kept on screen.
        let old = panel.frame
        var frame = NSRect(x: old.midX - size.points / 2, y: old.midY - size.points / 2, width: size.points, height: size.points)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true, animate: true)
        applyShape()
        content?.menu = makeMenu()
    }

    @objc private func pickShape(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let shape = CameraShape(rawValue: raw) else { return }
        prefs.cameraBubbleShape = shape
        applyShape()
        content?.menu = makeMenu()
    }

    @objc private func pickBorder(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let preset = RGBAColor.borderPresets.first(where: { $0.key == key }) else { return }
        prefs.cameraBorderColor = preset.color
        applyShape()
        content?.menu = makeMenu()
    }

    @objc private func pickCustomBorder() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.color = prefs.cameraBorderColor.nsColor
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.level = .floating
        NSApp.activate()
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        prefs.cameraBorderColor = RGBAColor(sender.color)
        applyShape()
        content?.menu = makeMenu()
    }

    private static func swatch(_ color: RGBAColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            if color.a == 0 {
                NSColor.secondaryLabelColor.setStroke()
                circle.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 3))
                slash.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3))
                slash.stroke()
            } else {
                color.nsColor.setFill()
                circle.fill()
                NSColor.black.withAlphaComponent(0.25).setStroke()
                circle.stroke()
            }
            return true
        }
    }

    private func applyShape() {
        guard let layer = content?.layer else { return }
        layer.borderColor = prefs.cameraBorderColor.nsColor.cgColor
        layer.cornerRadius = prefs.cameraBubbleSize.points / 2 * prefs.cameraBubbleShape.cornerFraction
        layer.cornerCurve = .continuous
        panel?.invalidateShadow()
    }
}
