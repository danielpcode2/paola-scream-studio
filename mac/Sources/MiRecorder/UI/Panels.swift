import AppKit
import SwiftUI

extension NSScreen {
    /// Frame in CG global coordinates (origin top-left of the primary display), as used by
    /// ScreenCaptureKit and CGWindowList.
    var cgFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    /// Screen under the mouse pointer.
    static var current: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}

/// CG global rect (top-left origin) -> Cocoa global rect (bottom-left origin).
func cocoaRect(fromCG rect: CGRect) -> NSRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

/// Borderless panel used for every floating piece of UI (toolbar, pickers, widgets, overlays).
/// All of them belong to this app, which is excluded from the screen capture.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    private let acceptsKey: Bool

    init(frame: NSRect, level: NSWindow.Level, acceptsKey: Bool = true, clickThrough: Bool = false) {
        self.acceptsKey = acceptsKey
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = clickThrough
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { acceptsKey }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let onConfirm { // Return / Enter
            onConfirm()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Hosts a SwiftUI view that re-renders when the language changes.
    func host<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: LocalizedRoot { view })
        hosting.sizingOptions = []
        contentView = hosting
    }
}

/// Re-creates its content when the app language changes, so every `tr(...)` is re-evaluated.
struct LocalizedRoot<Content: View>: View {
    @ObservedObject private var prefs = Preferences.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .id(prefs.language)
            .environment(\.locale, Locale(identifier: prefs.language.rawValue))
    }
}

extension Color {
    /// Accent used for primary recording actions.
    static let recordAccent = Color(red: 0.36, green: 0.30, blue: 0.95)
}

/// "Start recording" split button with the after-recording menu.
struct StartRecordingButton: View {
    @ObservedObject private var prefs = Preferences.shared
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Label(tr("start_recording"), systemImage: "record.circle")
                    .font(.title3.weight(.semibold))
                    .padding(.leading, 18)
                    .padding(.trailing, 12)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 28)

            Menu {
                Picker(tr("after_recording"), selection: $prefs.afterRecording) {
                    ForEach(AfterRecordingAction.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle(tr("auto_zooms"), isOn: $prefs.autoZoom)
                Divider()
                Button(tr("quick_export_settings")) { AppModel.shared.showSettings(.quickExport) }
            } label: {
                Image(systemName: "chevron.down").font(.body.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 44)
        }
        .foregroundStyle(.white)
        .background(Color.recordAccent, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}
