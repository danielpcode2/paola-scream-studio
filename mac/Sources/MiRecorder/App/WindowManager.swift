import AppKit
import Combine
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, editing, quickExport, shortcuts, advanced

    var id: String { rawValue }
    var title: String { tr("settings.tab.\(rawValue)") }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .editing: "pencil.and.outline"
        case .quickExport: "square.and.arrow.up"
        case .shortcuts: "command"
        case .advanced: "gearshape.2"
        }
    }
}

@MainActor
final class SettingsState: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// Owns the app's regular windows: projects, settings and one editor per project.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    let settingsState = SettingsState()
    var onChange: (() -> Void)?

    private var projectsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var editors: [NSWindow: EditorModel] = [:]
    private var editorObservers: [NSWindow: AnyCancellable] = [:]
    private var hidden: [NSWindow] = []
    private var keyMonitor: Any?

    private var allWindows: [NSWindow] {
        [projectsWindow, settingsWindow].compactMap { $0 } + Array(editors.keys)
    }

    var hasVisibleWindows: Bool { allWindows.contains { $0.isVisible } || !hidden.isEmpty }

    func showProjects() {
        let window = projectsWindow ?? makeWindow(size: NSSize(width: 1000, height: 660), view: ProjectsView())
        window.title = tr("projects.title")
        projectsWindow = window
        present(window)
    }

    func showSettings(_ tab: SettingsTab) {
        settingsState.tab = tab
        let window = settingsWindow ?? makeWindow(
            size: NSSize(width: 820, height: 680),
            view: SettingsView(state: settingsState),
            style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        )
        window.title = tr("settings.title")
        window.titlebarAppearsTransparent = true
        settingsWindow = window
        present(window)
    }

    func openEditor(_ folder: URL) throws {
        if let existing = editors.first(where: { $0.value.folder == folder })?.key {
            present(existing)
            return
        }
        let model = try EditorModel(folder: folder)
        let window = makeWindow(
            size: NSSize(width: 1480, height: 940),
            view: EditorView(model: model),
            style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        )
        window.title = model.title
        // The editor draws its own dark top bar next to the traffic lights.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.055, alpha: 1)
        window.setFrameAutosaveName("editor")
        editors[window] = model
        installKeyMonitor()
        editorObservers[window] = model.$isDirty.sink { [weak window] dirty in window?.isDocumentEdited = dirty }
        present(window)
        Task { await model.load() }
    }

    /// Editor shortcuts go through one handler that ignores keys typed into text fields.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let window = event.window, let model = self?.editors[window] else { return event }
                if let text = window.firstResponder as? NSTextView, text.isEditable { return event }
                return model.handleKey(event) ? nil : event
            }
        }
    }

    func closeEditor(for folder: URL) {
        guard let window = editors.first(where: { $0.value.folder == folder })?.key else { return }
        editors[window]?.discardChanges()
        window.close()
    }

    /// Hides our regular windows while recording (panels such as the camera bubble stay).
    func hideAll() {
        hidden = allWindows.filter(\.isVisible)
        hidden.forEach { $0.orderOut(nil) }
    }

    func restoreHidden() {
        let windows = hidden
        hidden = []
        guard !windows.isEmpty else { return }
        onChange?()
        NSApp.activate()
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    func refreshTitles() {
        projectsWindow?.title = tr("projects.title")
        settingsWindow?.title = tr("settings.title")
    }

    private func present(_ window: NSWindow) {
        if hidden.contains(window) { hidden.removeAll { $0 == window } }
        onChange?()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<V: View>(
        size: NSSize,
        view: V,
        style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    ) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: LocalizedRoot { view })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = editors[sender], model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = tr("editor.unsaved.title")
        alert.informativeText = tr("editor.unsaved.message")
        alert.addButton(withTitle: tr("save"))
        alert.addButton(withTitle: tr("dont_save"))
        alert.addButton(withTitle: tr("cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save()
            return true
        case .alertSecondButtonReturn:
            model.discardChanges()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let model = editors.removeValue(forKey: window) {
            model.close()
            editorObservers[window] = nil
        }
        // The window is still visible during this callback.
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}
