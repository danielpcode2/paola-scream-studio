import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    Button { state.tab = tab } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tab.icon).font(.system(size: 20))
                            Text(tab.title).font(.callout)
                        }
                        .frame(minWidth: 92)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(state.tab == tab ? Color.primary.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 30)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch state.tab {
                    case .general: GeneralSettings()
                    case .recording: RecordingSettings()
                    case .editing: EditingSettings()
                    case .quickExport: QuickExportSettings()
                    case .shortcuts: ShortcutSettings()
                    case .advanced: AdvancedSettings()
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

/// Title + description on the left, control on the right.
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var icon: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                if let icon {
                    Label(title, systemImage: icon).font(.title3)
                } else {
                    Text(title).font(.title3)
                }
                if let detail {
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var detail: String?
    var icon: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail, icon: icon) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.large)
        }
    }
}

private func chooseDirectory(start: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = start
    return panel.runModal() == .OK ? panel.url : nil
}

private func abbreviated(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var confirmReset = false

    var body: some View {
        ToggleRow(
            title: tr("settings.general.login"),
            detail: prefs.launchAtLoginError ?? tr("settings.general.login.detail"),
            isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.setLaunchAtLogin($0) })
        )
        ToggleRow(
            title: tr("settings.general.hide_dock"),
            detail: tr("settings.general.hide_dock.detail"),
            isOn: Binding(get: { !prefs.showInDock }, set: { prefs.showInDock = !$0 })
        )
        SettingRow(title: tr("settings.general.language"), detail: tr("settings.general.language.detail")) {
            Picker("", selection: $prefs.language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        Divider()
        SettingRow(title: tr("settings.general.privacy"), detail: tr("settings.general.privacy.detail")) {
            Image(systemName: "lock.shield").font(.title).foregroundStyle(.green)
        }
        Divider()
        Button(role: .destructive) { confirmReset = true } label: {
            Text(tr("settings.general.reset")).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .foregroundStyle(.red)
        .confirmationDialog(tr("settings.general.reset.confirm"), isPresented: $confirmReset) {
            Button(tr("settings.general.reset"), role: .destructive) { prefs.resetAll() }
        }
    }
}

// MARK: - Recording

private struct RecordingSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingRow(title: tr("settings.recording.directory"), detail: abbreviated(prefs.projectsDirectory)) {
            Button(tr("settings.change_directory")) {
                if let url = chooseDirectory(start: prefs.projectsDirectory) { prefs.projectsDirectory = url }
            }
            .controlSize(.large)
        }
        ToggleRow(title: tr("options.highlight_area"), detail: tr("settings.recording.highlight.detail"), isOn: $prefs.highlightRecordedArea)
        ToggleRow(title: tr("settings.recording.auto_zoom"), detail: tr("settings.recording.auto_zoom.detail"), isOn: $prefs.autoZoom)
        ToggleRow(title: tr("settings.recording.widget"), detail: tr("settings.recording.widget.detail"), isOn: $prefs.showRecordingWidget)
        SettingRow(title: tr("settings.recording.camera_resolution"), detail: tr("settings.recording.camera_resolution.detail")) {
            Picker("", selection: $prefs.cameraResolution) {
                ForEach(CameraResolution.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        Divider()
        SettingRow(title: tr("options.countdown"), detail: tr("settings.recording.countdown.detail")) {
            Picker("", selection: $prefs.countdown) {
                Text(tr("off")).tag(0)
                Text("3s").tag(3)
                Text("5s").tag(5)
                Text("10s").tag(10)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        ToggleRow(title: tr("options.hide_desktop_icons"), detail: tr("settings.recording.desktop.detail"), isOn: $prefs.hideDesktopIcons)
        ToggleRow(title: tr("options.hide_dock_icon"), detail: tr("settings.recording.hide_dock.detail"), isOn: $prefs.hideDockWhileRecording)
        ToggleRow(title: tr("options.speaker_notes"), detail: tr("settings.recording.notes.detail"), isOn: $prefs.showSpeakerNotes)
        ToggleRow(
            title: tr("settings.recording.keystrokes"),
            detail: tr("settings.recording.keystrokes.detail") + (Keystrokes.isAllowed ? "" : " " + tr("settings.recording.keystrokes.permission")),
            isOn: $prefs.recordKeystrokes
        )
    }
}

// MARK: - Editing

private struct EditingSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        ToggleRow(title: tr("settings.editing.last_settings"), detail: tr("settings.editing.last_settings.detail"), isOn: $prefs.useLastProjectSettings)
        ToggleRow(title: tr("settings.editing.autosave"), detail: tr("settings.editing.autosave.detail"), isOn: $prefs.autosave)
        SettingRow(title: tr("settings.editing.presets_dir"), detail: abbreviated(prefs.presetsDirectory)) {
            Button(tr("settings.change_directory")) {
                if let url = chooseDirectory(start: prefs.presetsDirectory) { prefs.presetsDirectory = url }
            }
            .controlSize(.large)
        }
        SettingRow(title: tr("presets.default"), detail: tr("settings.editing.default_preset.detail")) {
            Picker("", selection: $prefs.defaultPresetName) {
                Text(tr("presets.no_default")).tag(String?.none)
                ForEach(PresetStore.all()) { Text($0.name).tag(Optional($0.name)) }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }
}

// MARK: - Quick export

private struct QuickExportSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tr("settings.quick.title"), systemImage: "square.and.arrow.up").font(.title3)
            Text(tr("settings.quick.detail")).foregroundStyle(.secondary)
        }
        ExportOptionsForm(options: $prefs.quickExport)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        SettingRow(title: tr("after_recording"), icon: "clock.arrow.circlepath") {
            Picker("", selection: $prefs.afterRecording) {
                ForEach(AfterRecordingAction.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 240)
        }
        ToggleRow(title: tr("settings.quick.widget"), detail: tr("settings.quick.widget.detail"), icon: "rectangle.bottomhalf.inset.filled", isOn: $prefs.showQuickExportWidget)
        ToggleRow(title: tr("settings.quick.always_save"), detail: tr("settings.quick.always_save.detail"), icon: "folder", isOn: $prefs.alwaysSaveProject)
        SettingRow(title: tr("settings.quick.exports_folder"), detail: abbreviated(ProjectStore.exportsDirectory)) {
            Button(tr("settings.show_in_finder")) {
                try? FileManager.default.createDirectory(at: ProjectStore.exportsDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(ProjectStore.exportsDirectory)
            }
            .controlSize(.large)
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var app = AppModel.shared
    @State private var editing = false

    var body: some View {
        HStack {
            Spacer()
            Picker("", selection: $editing) {
                Label(tr("settings.shortcuts.recording"), systemImage: "record.circle").tag(false)
                Label(tr("settings.shortcuts.editing"), systemImage: "play.circle").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            Spacer()
        }
        if editing {
            ForEach(EditingShortcut.all, id: \.title) { item in
                SettingRow(title: item.title, icon: item.icon) {
                    Text(item.keys)
                        .font(.system(.body, design: .rounded))
                        .frame(minWidth: 150)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                }
            }
            Text(tr("settings.shortcuts.editing.note")).font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(ShortcutAction.allCases) { action in
                SettingRow(
                    title: action.title,
                    detail: app.failedShortcuts.contains(action) ? tr("settings.shortcuts.conflict") : action.detail,
                    icon: action.icon
                ) {
                    HStack(spacing: 10) {
                        Button {
                            prefs.shortcuts[action] = .some(nil)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help(tr("settings.shortcuts.remove"))
                        ShortcutRecorderButton(combo: Binding(
                            get: { prefs.shortcut(for: action) },
                            set: { prefs.shortcuts[action] = .some($0) }
                        ))
                    }
                }
            }
            Button(tr("settings.shortcuts.restore")) { prefs.shortcuts = ShortcutAction.defaults }
        }
    }

    private struct EditingShortcut {
        let title: String
        let icon: String
        let keys: String

        static var all: [EditingShortcut] {
            [
                .init(title: tr("shortcut.edit.play"), icon: "playpause", keys: "Space"),
                .init(title: tr("editor.zoom_here"), icon: "plus.magnifyingglass", keys: "Z"),
                .init(title: tr("shortcut.edit.trim_start"), icon: "arrow.right.to.line", keys: "["),
                .init(title: tr("shortcut.edit.trim_end"), icon: "arrow.left.to.line", keys: "]"),
                .init(title: tr("shortcut.edit.delete_zoom"), icon: "trash", keys: "⌫"),
                .init(title: tr("add.cut"), icon: "scissors", keys: "X"),
                .init(title: tr("shortcut.edit.split"), icon: "scissors", keys: "C"),
                .init(title: tr("shortcut.edit.duplicate"), icon: "plus.square.on.square", keys: "⌘D"),
                .init(title: tr("shortcut.edit.toggle"), icon: "nosign", keys: "D"),
                .init(title: tr("shortcut.edit.copy"), icon: "doc.on.doc", keys: "⌘C ⌘X ⌘V"),
                .init(title: tr("editor.undo"), icon: "arrow.uturn.backward", keys: "⌘Z ⇧⌘Z"),
                .init(title: tr("annotation.kind.text"), icon: "textformat", keys: "T"),
                .init(title: tr("save"), icon: "square.and.arrow.down", keys: "⌘S"),
                .init(title: tr("editor.export"), icon: "square.and.arrow.up", keys: "⌘E"),
                .init(title: tr("menu.show_settings"), icon: "gearshape", keys: "⌘,"),
            ]
        }
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    var body: some View {
        SettingRow(title: tr("settings.advanced.diagnostics"), detail: tr("settings.advanced.diagnostics.detail")) {
            Button(tr("settings.advanced.diagnostics.button")) { Diagnostics.saveReport() }
                .controlSize(.large)
        }
        Divider()
        SettingRow(title: tr("settings.advanced.permissions"), detail: tr("settings.advanced.permissions.detail")) {
            Button(tr("settings.advanced.permissions.button")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.large)
        }
        SettingRow(title: tr("settings.advanced.projects_folder"), detail: abbreviated(ProjectStore.root)) {
            Button(tr("settings.show_in_finder")) {
                try? FileManager.default.createDirectory(at: ProjectStore.root, withIntermediateDirectories: true)
                NSWorkspace.shared.open(ProjectStore.root)
            }
            .controlSize(.large)
        }
    }
}

/// Local diagnostics report (never sent anywhere): versions, devices and permission states.
@MainActor
enum Diagnostics {
    static func report() -> String {
        let info = Bundle.main.infoDictionary
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelName = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        func status(_ type: AVMediaType) -> String {
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: "authorized"
            case .denied: "denied"
            case .restricted: "restricted"
            case .notDetermined: "not determined"
            @unknown default: "unknown"
            }
        }

        var lines = [
            "Mi Recorder \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "-"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Hardware: \(modelName)",
            "Screen recording permission: \(CGPreflightScreenCaptureAccess() ? "granted" : "not granted")",
            "Camera permission: \(status(.video))",
            "Microphone permission: \(status(.audio))",
            "Language: \(Preferences.shared.language.rawValue)",
            "",
            "Displays:",
        ]
        for screen in NSScreen.screens {
            lines.append("  - \(screen.localizedName) \(Int(screen.frame.width))x\(Int(screen.frame.height)) @\(screen.backingScaleFactor)x \(screen.maximumFramesPerSecond)fps")
        }
        lines.append("Cameras:")
        CameraRecorder.availableDevices().forEach { lines.append("  - \($0.name)") }
        lines.append("Microphones:")
        AudioDevice.microphones().forEach { lines.append("  - \($0.name)") }
        lines.append("Projects: \(ProjectStore.recentProjects().count)")
        return lines.joined(separator: "\n")
    }

    static func saveReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MiRecorder-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            Hud.show(error.localizedDescription)
        }
    }
}
