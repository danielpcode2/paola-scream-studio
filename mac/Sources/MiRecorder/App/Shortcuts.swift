import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key + modifiers combination, stored with Carbon key code and modifier mask.
struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String

    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key
    }

    /// Builds a combo from a key press; requires ⌘, ⌃ or ⌥ so it can work globally.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= Self.command }
        if flags.contains(.shift) { mask |= Self.shift }
        if flags.contains(.option) { mask |= Self.option }
        if flags.contains(.control) { mask |= Self.control }
        guard mask & (Self.command | Self.control | Self.option) != 0 else { return nil }
        let code = UInt32(event.keyCode)
        let name = Self.specialNames[Int(code)] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !name.isEmpty else { return nil }
        self.init(keyCode: code, modifiers: mask, key: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let specialNames: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Space: "Space", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Key equivalent for showing the shortcut in SwiftUI menus.
    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "↩": .return
        case "⌫": .delete
        case "⌦": .deleteForward
        case "Space": .space
        case "⇥": .tab
        case "⎋": .escape
        case "←": .leftArrow
        case "→": .rightArrow
        case "↑": .upArrow
        case "↓": .downArrow
        default: key.count == 1 ? KeyEquivalent(Character(key.lowercased())) : nil
        }
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers & Self.command != 0 { result.insert(.command) }
        if modifiers & Self.shift != 0 { result.insert(.shift) }
        if modifiers & Self.option != 0 { result.insert(.option) }
        if modifiers & Self.control != 0 { result.insert(.control) }
        return result
    }
}

enum ShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case newRecording, pauseResume, restart, flag, recordDisplay, recordWindow, recordArea, speakerNotes, prompter, toggleControls

    var id: String { rawValue }

    var title: String { tr("shortcut.\(rawValue)") }

    var detail: String? {
        switch self {
        case .newRecording: tr("shortcut.newRecording.detail")
        case .flag: tr("shortcut.flag.detail")
        case .toggleControls: tr("shortcut.toggleControls.detail")
        default: nil
        }
    }

    var icon: String {
        switch self {
        case .newRecording: "record.circle"
        case .pauseResume: "playpause"
        case .restart: "arrow.counterclockwise"
        case .flag: "flag"
        case .recordDisplay: "menubar.dock.rectangle"
        case .recordWindow: "macwindow"
        case .recordArea: "rectangle.dashed"
        case .speakerNotes: "note.text"
        case .prompter: "text.line.first.and.arrowtriangle.forward"
        case .toggleControls: "rectangle.dashed.badge.record"
        }
    }

    static let defaults: [ShortcutAction: KeyCombo?] = [
        .newRecording: KeyCombo(keyCode: UInt32(kVK_Return), modifiers: KeyCombo.command | KeyCombo.control, key: "↩"),
        .pauseResume: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: KeyCombo.command | KeyCombo.option, key: "P"),
        .restart: KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: KeyCombo.command | KeyCombo.option, key: "⌫"),
        .flag: KeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: KeyCombo.command | KeyCombo.option | KeyCombo.control, key: "F"),
        .recordDisplay: KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: KeyCombo.command | KeyCombo.option, key: "3"),
        .recordWindow: KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: KeyCombo.command | KeyCombo.option, key: "4"),
        .recordArea: KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: KeyCombo.command | KeyCombo.option, key: "5"),
        .speakerNotes: KeyCombo(keyCode: UInt32(kVK_ANSI_Slash), modifiers: KeyCombo.command | KeyCombo.option, key: "/"),
        .prompter: KeyCombo(keyCode: UInt32(kVK_ANSI_Period), modifiers: KeyCombo.command | KeyCombo.option, key: "."),
        .toggleControls: KeyCombo(keyCode: UInt32(kVK_ANSI_Quote), modifiers: KeyCombo.command | KeyCombo.option, key: "'"),
    ]
}

/// System-wide hot keys via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var bindings: [(KeyCombo, () -> Void)] = []
    private var installed = false
    private var suspended = false

    /// Registers the bindings and returns the combos that could not be registered (taken by another app).
    @discardableResult
    func register(_ bindings: [(KeyCombo, () -> Void)]) -> [KeyCombo] {
        self.bindings = bindings
        return suspended ? [] : apply()
    }

    /// Temporarily releases all hot keys (e.g. while recording a new shortcut).
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        apply()
    }

    @discardableResult
    private func apply() -> [KeyCombo] {
        unregisterAll()
        installIfNeeded()
        var failed: [KeyCombo] = []
        for (index, (combo, action)) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode, combo.modifiers,
                EventHotKeyID(signature: OSType(0x4D52_5243), id: id),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                handlers[id] = action
            } else {
                failed.append(combo)
            }
        }
        return failed
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        handlers = [:]
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey
            )
            let id = hotKey.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Click, then press the new combination. Esc cancels.
struct ShortcutRecorderButton: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? tr("shortcuts.press_keys") : (combo?.display ?? tr("shortcuts.none")))
                .font(.system(.body, design: .rounded))
                .frame(minWidth: 150)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let newCombo = KeyCombo(event: event) {
                combo = newCombo
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            HotKeyCenter.shared.resume()
        }
    }
}
