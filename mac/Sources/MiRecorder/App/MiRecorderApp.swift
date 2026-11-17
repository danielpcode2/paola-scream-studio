import AppKit
import SwiftUI

@main
struct MiRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var prefs = Preferences.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarIcon(recorder: AppModel.shared.recorder)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(tr("menu.show_settings")) { AppModel.shared.showSettings(.general) }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(tr("menu.new_recording")) { AppModel.shared.newRecording() }
                    .shortcut(.newRecording)
                Button(tr("menu.open_project")) { AppModel.shared.openProjectPanel() }
                    .keyboardShortcut("o")
                Button(tr("menu.open_last")) { AppModel.shared.openLastProject() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                Button(tr("menu.show_projects")) { AppModel.shared.showProjects() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }

    /// Clicking the Dock icon with no windows open shows the projects.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared.showProjects() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MenuBarIcon: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        Image(systemName: recorder.isActive ? "record.circle.fill" : "record.circle")
    }
}

/// Menu bar menu: recording actions, settings, Dock, projects, language and quit.
private struct MenuBarMenu: View {
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var recorder = AppModel.shared.recorder
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if recorder.isActive {
            Button { Task { await app.stopRecording() } } label: {
                Label(tr("menu.finish"), systemImage: "stop.circle")
            }
            .shortcut(.newRecording)
            Button { Task { await app.togglePause() } } label: {
                Label(recorder.state == .paused ? tr("menu.resume") : tr("menu.pause"), systemImage: "playpause")
            }
            .shortcut(.pauseResume)
            Button { Task { await app.restartRecording() } } label: {
                Label(tr("menu.restart"), systemImage: "arrow.counterclockwise")
            }
            .shortcut(.restart)
            Button { app.addFlag() } label: {
                Label(tr("menu.flag"), systemImage: "flag")
            }
            .shortcut(.flag)
            Button { app.toggleControls() } label: {
                Label(tr("menu.toggle_controls"), systemImage: "rectangle.dashed.badge.record")
            }
            .shortcut(.toggleControls)
            Button { Task { await app.cancelRecording() } } label: {
                Label(tr("menu.cancel_recording"), systemImage: "trash")
            }
        } else {
            Button { app.newRecording() } label: {
                Label(tr("menu.new_recording"), systemImage: "record.circle")
            }
            .shortcut(.newRecording)
            Divider()
            Button { app.perform(.recordDisplay) } label: {
                Label(tr("menu.record_display"), systemImage: "menubar.dock.rectangle")
            }
            .shortcut(.recordDisplay)
            Button { app.perform(.recordWindow) } label: {
                Label(tr("menu.record_window"), systemImage: "macwindow")
            }
            .shortcut(.recordWindow)
            Button { app.perform(.recordArea) } label: {
                Label(tr("menu.record_area"), systemImage: "rectangle.dashed")
            }
            .shortcut(.recordArea)
        }
        Button { app.notes.show() } label: {
            Label(tr("menu.speaker_notes"), systemImage: "note.text")
        }
        .shortcut(.speakerNotes)
        Divider()
        Button(tr("menu.show_settings")) { app.showSettings(.general) }
            .keyboardShortcut(",")
        Toggle(tr("menu.show_in_dock"), isOn: $prefs.showInDock)
            .keyboardShortcut("d")
        Button(tr("menu.show_projects")) { app.showProjects() }
        Divider()
        Button(tr("menu.open_project")) { app.openProjectPanel() }
            .keyboardShortcut("o")
        Divider()
        Button(tr("menu.open_last")) { app.openLastProject() }
            .keyboardShortcut("z", modifiers: [.command, .option])
        Divider()
        Picker(tr("menu.language"), selection: $prefs.language) {
            ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
        }
        Divider()
        Button(tr("menu.quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension View {
    /// Shows the user's configured shortcut for an action next to a menu item.
    @ViewBuilder
    func shortcut(_ action: ShortcutAction) -> some View {
        if let combo = Preferences.shared.shortcut(for: action), let key = combo.keyEquivalent {
            keyboardShortcut(key, modifiers: combo.eventModifiers)
        } else {
            self
        }
    }
}
