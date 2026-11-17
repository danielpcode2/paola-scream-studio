import AppKit
import SwiftUI

enum CaptureMode: String, CaseIterable, Identifiable {
    case display, window, area

    var id: String { rawValue }
}

/// Floating "new recording" bar: pick Display / Window / Area, camera, microphone, system audio and options.
@MainActor
final class RecordingToolbarController {
    private var panel: FloatingPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let screen = NSScreen.current ?? NSScreen.screens[0]
        let size = NSSize(width: 1090, height: 84)
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 40, width: size.width, height: size.height)
        let panel = panel ?? FloatingPanel(frame: frame, level: .floating)
        panel.isMovableByWindowBackground = true
        panel.onCancel = {
            // Esc closes the projects panel first, then the toolbar.
            if AppModel.shared.projectsOverlayVisible {
                AppModel.shared.hideProjectsOverlay()
            } else {
                AppModel.shared.closeToolbar()
            }
        }
        panel.host(RecordingToolbarView())
        if !panel.isVisible { panel.setFrame(frame, display: true) }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    var screen: NSScreen? { panel?.screen }

    func bringToFront() {
        guard let panel, panel.isVisible else { return }
        panel.orderFrontRegardless()
    }
}

private struct RecordingToolbarView: View {
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var mic = AppModel.shared.mic

    var body: some View {
        HStack(spacing: 4) {
            Button { app.closeToolbar() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 26)).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help(tr("close"))
            .padding(.trailing, 6)

            Separator()
            ModeButton(icon: "menubar.dock.rectangle", title: tr("mode.display")) { start(.display) }
            ModeButton(icon: "macwindow", title: tr("mode.window")) { start(.window) }
            ModeButton(icon: "rectangle.dashed", title: tr("mode.area")) { start(.area) }
            DeviceMenu()
            Separator()

            Menu {
                Button(tr("camera.none")) { prefs.cameraID = nil }
                Divider()
                ForEach(app.cameras) { device in
                    Toggle(device.name, isOn: Binding(get: { prefs.cameraID == device.id }, set: { _ in prefs.cameraID = device.id }))
                }
            } label: {
                DeviceLabel(
                    icon: prefs.cameraID == nil ? "video.slash" : "video",
                    text: app.cameras.first { $0.id == prefs.cameraID }?.name ?? tr("camera.none"),
                    active: prefs.cameraID != nil
                )
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)

            VStack(spacing: 3) {
                Menu {
                    Button(tr("mic.none")) { prefs.microphoneID = nil }
                    Divider()
                    ForEach(app.microphones) { device in
                        Toggle(device.name, isOn: Binding(get: { prefs.microphoneID == device.id }, set: { _ in prefs.microphoneID = device.id }))
                    }
                } label: {
                    DeviceLabel(
                        icon: prefs.microphoneID == nil ? "mic.slash" : "mic",
                        text: app.microphones.first { $0.id == prefs.microphoneID }?.name ?? tr("mic.none"),
                        active: prefs.microphoneID != nil
                    )
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                if prefs.microphoneID != nil {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(.white.opacity(0.85)).frame(width: geometry.size.width * mic.level)
                        }
                    }
                    .frame(width: 150, height: 3)
                    .animation(.linear(duration: 0.1), value: mic.level)
                }
            }

            Button { prefs.captureSystemAudio.toggle() } label: {
                DeviceLabel(
                    icon: prefs.captureSystemAudio ? "speaker.wave.2" : "speaker.slash",
                    text: prefs.captureSystemAudio ? tr("audio.system") : tr("audio.no_system"),
                    active: prefs.captureSystemAudio
                )
            }
            .buttonStyle(.plain)

            Separator()
            Button { app.toggleProjectsOverlay() } label: {
                Image(systemName: app.projectsOverlayVisible ? "folder.fill" : "folder")
                    .font(.system(size: 20))
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(app.projectsOverlayVisible ? 0.14 : 0)))
            }
            .buttonStyle(.plain)
            .help(tr("menu.show_projects"))

            OptionsMenu()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.09).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func start(_ mode: CaptureMode) {
        Task { await app.beginRecording(mode) }
    }
}

private struct OptionsMenu: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Menu {
            Section(tr("options.before")) {
                Picker(tr("options.countdown"), selection: $prefs.countdown) {
                    Text(tr("off")).tag(0)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                }
            }
            Section(tr("options.while")) {
                Toggle(tr("options.hide_desktop_icons"), isOn: $prefs.hideDesktopIcons)
                Toggle(tr("options.hide_dock_icon"), isOn: $prefs.hideDockWhileRecording)
                Toggle(tr("options.highlight_area"), isOn: $prefs.highlightRecordedArea)
                Toggle(tr("options.speaker_notes"), isOn: $prefs.showSpeakerNotes)
                Button(tr("menu.speaker_notes")) { AppModel.shared.notes.show() }
            }
            Section(tr("after_recording")) {
                Toggle(tr("options.quick_widget"), isOn: $prefs.showQuickExportWidget)
            }
            Menu(tr("options.advanced")) {
                Toggle(tr("settings.recording.widget"), isOn: $prefs.showRecordingWidget)
                Picker(tr("settings.recording.camera_resolution"), selection: $prefs.cameraResolution) {
                    ForEach(CameraResolution.allCases) { Text($0.label).tag($0) }
                }
            }
            Divider()
            Button(tr("menu.settings")) { AppModel.shared.showSettings(.general) }
                .keyboardShortcut(",")
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "gearshape").font(.system(size: 20))
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .frame(height: 40)
            .padding(.horizontal, 6)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// iPhone / iPad connected by USB.
private struct DeviceMenu: View {
    @ObservedObject private var app = AppModel.shared
    @State private var hovering = false

    var body: some View {
        Menu {
            if app.mobileDevices.isEmpty {
                Text(tr("device.none"))
            } else {
                ForEach(app.mobileDevices) { device in
                    Button(device.name) { Task { await app.beginDeviceRecording(device.id) } }
                }
            }
            Divider()
            Button(tr("device.how")) { app.showDeviceHelp() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "iphone").font(.system(size: 22))
                Text(tr("mode.device")).font(.caption)
            }
            .frame(width: 76, height: 62)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { app.refreshDevices() })
    }
}

private struct ModeButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 22))
                Text(title).font(.caption)
            }
            .frame(width: 76, height: 62)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct DeviceLabel: View {
    let icon: String
    let text: String
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 18))
            Text(text).lineLimit(1).truncationMode(.tail).frame(maxWidth: 130, alignment: .leading)
        }
        .foregroundStyle(active ? .white : .white.opacity(0.5))
        .padding(.horizontal, 10)
        .frame(height: 40)
        .contentShape(Rectangle())
    }
}

private struct Separator: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 40).padding(.horizontal, 8)
    }
}
