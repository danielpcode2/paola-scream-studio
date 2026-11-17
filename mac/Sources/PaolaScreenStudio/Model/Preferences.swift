import Foundation
import ServiceManagement

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case es, en

    var id: String { rawValue }
    var displayName: String { self == .es ? "Español" : "English" }

    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("es") == true ? .es : .en
    }

    static var current: AppLanguage { Preferences.load(Preferences.Key.language, systemDefault) }
}

enum CameraResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case p720, p1080, p4k

    var id: String { rawValue }
    var label: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p4k: "4K"
        }
    }
}

enum AfterRecordingAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case createProject, exportCopy, exportSave

    var id: String { rawValue }
    var label: String {
        switch self {
        case .createProject: tr("after.create_project")
        case .exportCopy: tr("after.export_copy")
        case .exportSave: tr("after.export_save")
        }
    }
}

/// App-wide preferences persisted in UserDefaults (JSON-encoded values).
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    enum Key {
        static let language = "language"
        static let showInDock = "showInDock"
        static let projectsDirectory = "projectsDirectory"
        static let highlightRecordedArea = "highlightRecordedArea"
        static let autoZoom = "autoZoom"
        static let showRecordingWidget = "showRecordingWidget"
        static let cameraResolution = "cameraResolution"
        static let useLastProjectSettings = "useLastProjectSettings"
        static let lastProjectSettings = "lastProjectSettings"
        static let autosave = "autosave"
        static let presetsDirectory = "presetsDirectory"
        static let defaultPresetName = "defaultPresetName"
        static let quickExport = "quickExport"
        static let showQuickExportWidget = "showQuickExportWidget"
        static let alwaysSaveProject = "alwaysSaveProject"
        static let afterRecording = "afterRecording"
        static let shortcuts = "shortcuts"
        static let countdown = "countdown"
        static let hideDesktopIcons = "hideDesktopIcons"
        static let hideDockWhileRecording = "hideDockWhileRecording"
        static let showSpeakerNotes = "showSpeakerNotes"
        static let speakerNotes = "speakerNotes"
        static let prompterSpeed = "prompterSpeed"
        static let captureSystemAudio = "captureSystemAudio"
        static let microphoneID = "microphoneID"
        static let cameraID = "cameraID"
        static let cameraBubbleSize = "cameraBubbleSize"
        static let cameraBubbleShape = "cameraBubbleShape"
        static let cameraBorderColor = "cameraBorderColor"
        static let recordKeystrokes = "recordKeystrokes"

        static let all = [
            language, showInDock, projectsDirectory, highlightRecordedArea, autoZoom, showRecordingWidget,
            cameraResolution, useLastProjectSettings, lastProjectSettings, autosave, presetsDirectory,
            defaultPresetName, quickExport, showQuickExportWidget, alwaysSaveProject, afterRecording, shortcuts,
            countdown, hideDesktopIcons, hideDockWhileRecording, showSpeakerNotes, speakerNotes, prompterSpeed,
            captureSystemAudio, microphoneID, cameraID, cameraBubbleSize, cameraBubbleShape, cameraBorderColor, recordKeystrokes,
        ]
    }

    /// `~/Movies/Paola Screen Studio`, or the folder used before the rename if it already holds projects.
    nonisolated static var defaultProjectsDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return preferringLegacy(movies.appending(path: "Paola Screen Studio", directoryHint: .isDirectory),
                                legacy: movies.appending(path: "MiRecorder", directoryHint: .isDirectory))
    }

    nonisolated static var defaultPresetsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return preferringLegacy(documents.appending(path: "Paola Screen Studio Presets", directoryHint: .isDirectory),
                                legacy: documents.appending(path: "Mi Recorder Presets", directoryHint: .isDirectory))
    }

    private nonisolated static func preferringLegacy(_ current: URL, legacy: URL) -> URL {
        let files = FileManager.default
        return !files.fileExists(atPath: current.path) && files.fileExists(atPath: legacy.path) ? legacy : current
    }

    /// Readable from any thread (ProjectStore, PresetStore).
    nonisolated static var storedProjectsDirectory: URL { load(Key.projectsDirectory, defaultProjectsDirectory) }
    nonisolated static var storedPresetsDirectory: URL { load(Key.presetsDirectory, defaultPresetsDirectory) }

    @Published var language = load(Key.language, AppLanguage.systemDefault) { didSet { save(language, Key.language) } }
    @Published var showInDock = load(Key.showInDock, true) { didSet { save(showInDock, Key.showInDock) } }
    @Published var projectsDirectory = load(Key.projectsDirectory, defaultProjectsDirectory) { didSet { save(projectsDirectory, Key.projectsDirectory) } }
    @Published var highlightRecordedArea = load(Key.highlightRecordedArea, true) { didSet { save(highlightRecordedArea, Key.highlightRecordedArea) } }
    @Published var autoZoom = load(Key.autoZoom, true) { didSet { save(autoZoom, Key.autoZoom) } }
    @Published var showRecordingWidget = load(Key.showRecordingWidget, true) { didSet { save(showRecordingWidget, Key.showRecordingWidget) } }
    @Published var cameraResolution = load(Key.cameraResolution, CameraResolution.p1080) { didSet { save(cameraResolution, Key.cameraResolution) } }
    @Published var useLastProjectSettings = load(Key.useLastProjectSettings, false) { didSet { save(useLastProjectSettings, Key.useLastProjectSettings) } }
    @Published var lastProjectSettings = load(Key.lastProjectSettings, EditSettings?.none) { didSet { save(lastProjectSettings, Key.lastProjectSettings) } }
    @Published var autosave = load(Key.autosave, true) { didSet { save(autosave, Key.autosave) } }
    @Published var presetsDirectory = load(Key.presetsDirectory, defaultPresetsDirectory) { didSet { save(presetsDirectory, Key.presetsDirectory) } }
    @Published var defaultPresetName = load(Key.defaultPresetName, String?.none) { didSet { save(defaultPresetName, Key.defaultPresetName) } }
    @Published var quickExport = load(Key.quickExport, ExportOptions()) { didSet { save(quickExport, Key.quickExport) } }
    @Published var showQuickExportWidget = load(Key.showQuickExportWidget, true) { didSet { save(showQuickExportWidget, Key.showQuickExportWidget) } }
    @Published var alwaysSaveProject = load(Key.alwaysSaveProject, false) { didSet { save(alwaysSaveProject, Key.alwaysSaveProject) } }
    @Published var afterRecording = load(Key.afterRecording, AfterRecordingAction.createProject) { didSet { save(afterRecording, Key.afterRecording) } }
    @Published var shortcuts = load(Key.shortcuts, ShortcutAction.defaults) { didSet { save(shortcuts, Key.shortcuts) } }
    @Published var countdown = load(Key.countdown, 0) { didSet { save(countdown, Key.countdown) } }
    @Published var hideDesktopIcons = load(Key.hideDesktopIcons, false) { didSet { save(hideDesktopIcons, Key.hideDesktopIcons) } }
    @Published var hideDockWhileRecording = load(Key.hideDockWhileRecording, true) { didSet { save(hideDockWhileRecording, Key.hideDockWhileRecording) } }
    @Published var showSpeakerNotes = load(Key.showSpeakerNotes, false) { didSet { save(showSpeakerNotes, Key.showSpeakerNotes) } }
    @Published var speakerNotes = load(Key.speakerNotes, "") { didSet { save(speakerNotes, Key.speakerNotes) } }
    @Published var prompterSpeed = load(Key.prompterSpeed, 40.0) { didSet { save(prompterSpeed, Key.prompterSpeed) } }
    @Published var captureSystemAudio = load(Key.captureSystemAudio, true) { didSet { save(captureSystemAudio, Key.captureSystemAudio) } }
    /// nil = no microphone.
    @Published var microphoneID = load(Key.microphoneID, String?.none) { didSet { save(microphoneID, Key.microphoneID) } }
    /// nil = no camera.
    @Published var cameraID = load(Key.cameraID, String?.none) { didSet { save(cameraID, Key.cameraID) } }
    /// Diameter in points of the live camera bubble shown while recording.
    @Published var cameraBubbleSize = load(Key.cameraBubbleSize, CameraBubbleSize.medium) { didSet { save(cameraBubbleSize, Key.cameraBubbleSize) } }
    /// Shape of the live bubble; new projects use it for the camera in the video too.
    @Published var cameraBubbleShape = load(Key.cameraBubbleShape, CameraShape.circle) { didSet { save(cameraBubbleShape, Key.cameraBubbleShape) } }
    /// Border of the live bubble; new projects use it for the camera in the video too.
    @Published var cameraBorderColor = load(Key.cameraBorderColor, EditSettings().cameraBorderColor) { didSet { save(cameraBorderColor, Key.cameraBorderColor) } }
    /// Record keyboard shortcuts (⌘/⌃/⌥ combinations only) to show them in the video.
    @Published var recordKeystrokes = load(Key.recordKeystrokes, true) { didSet { save(recordKeystrokes, Key.recordKeystrokes) } }

    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchAtLoginError: String?

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func shortcut(for action: ShortcutAction) -> KeyCombo? {
        // Stored nil means "deleted by the user"; a missing key falls back to the default.
        if let stored = shortcuts[action] { return stored }
        return ShortcutAction.defaults[action] ?? nil
    }

    func resetAll() {
        Key.all.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let fresh = Preferences(fromStore: ())
        language = fresh.language
        showInDock = fresh.showInDock
        projectsDirectory = fresh.projectsDirectory
        highlightRecordedArea = fresh.highlightRecordedArea
        autoZoom = fresh.autoZoom
        showRecordingWidget = fresh.showRecordingWidget
        cameraResolution = fresh.cameraResolution
        useLastProjectSettings = fresh.useLastProjectSettings
        lastProjectSettings = fresh.lastProjectSettings
        autosave = fresh.autosave
        presetsDirectory = fresh.presetsDirectory
        defaultPresetName = fresh.defaultPresetName
        quickExport = fresh.quickExport
        showQuickExportWidget = fresh.showQuickExportWidget
        alwaysSaveProject = fresh.alwaysSaveProject
        afterRecording = fresh.afterRecording
        shortcuts = fresh.shortcuts
        countdown = fresh.countdown
        hideDesktopIcons = fresh.hideDesktopIcons
        hideDockWhileRecording = fresh.hideDockWhileRecording
        showSpeakerNotes = fresh.showSpeakerNotes
        speakerNotes = fresh.speakerNotes
        prompterSpeed = fresh.prompterSpeed
        captureSystemAudio = fresh.captureSystemAudio
        microphoneID = fresh.microphoneID
        cameraID = fresh.cameraID
        cameraBubbleSize = fresh.cameraBubbleSize
        cameraBubbleShape = fresh.cameraBubbleShape
        cameraBorderColor = fresh.cameraBorderColor
        recordKeystrokes = fresh.recordKeystrokes
    }

    private init() {}
    /// Builds a throwaway instance with values read from (now empty) storage, i.e. the defaults.
    private init(fromStore: Void) {}

    nonisolated static func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data)
        else { return fallback }
        return value
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
        objectWillChangeHook?()
    }

    /// Lets the coordinator react to any preference change (hot keys, Dock policy).
    var objectWillChangeHook: (() -> Void)?
}
