import AppKit
import ApplicationServices

/// Samples the mouse at 60 Hz and records clicks while a recording runs.
/// Mouse monitors do not need Accessibility permission (only keyboard monitors do).
@MainActor
final class CursorTracker {
    private typealias Point = (t: TimeInterval, p: CGPoint)

    private var timer: Timer?
    private var monitors: [Any] = []
    private var samples: [Point] = []
    private var clicks: [Point] = []
    private var keys: [(t: TimeInterval, label: String)] = []

    func start(keystrokes: Bool = false) {
        stop()
        samples = []
        clicks = []
        keys = []
        sample()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.recordClick(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.recordClick(event) }
            return event
        }) {
            monitors.append(local)
        }
        // Only shortcut combinations (⌘, ⌃ or ⌥ + key) are kept: plain typing such as passwords never is.
        // Global key monitoring needs the Accessibility permission; without it nothing is recorded.
        if keystrokes, let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let combo = KeyCombo(event: event) { self?.keys.append((event.timestamp, combo.display)) }
            }
        }) {
            monitors.append(keyMonitor)
        }
    }

    func keystrokes(clock: RecordingClock) -> [KeyStroke] {
        keys.compactMap { key in clock.projectTime(key.t).map { KeyStroke(t: $0, label: key.label) } }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Converts raw samples into a track normalized to `frame` (CG global points) on the project timeline.
    func track(clock: RecordingClock, frame: CGRect) -> CursorTrack {
        let firstStart = clock.segments.first?.startUptime ?? 0
        func normalize(_ point: Point) -> CursorSample? {
            guard let t = clock.projectTime(point.t) else { return nil }
            return CursorSample(
                t: t,
                x: (point.p.x - frame.minX) / max(frame.width, 1),
                y: (point.p.y - frame.minY) / max(frame.height, 1)
            )
        }
        // Keep only the last sample from before the recording started, as the position at t = 0.
        let preRoll = samples.last { $0.t < firstStart }
        let recorded = samples.filter { $0.t >= firstStart }
        let points = (preRoll.map { [$0] } ?? []) + recorded
        return CursorTrack(
            samples: points.compactMap(normalize),
            clicks: clicks.filter { $0.t >= firstStart }.compactMap(normalize)
        )
    }

    private func sample() {
        samples.append((ProcessInfo.processInfo.systemUptime, Self.globalPoint()))
    }

    private func recordClick(_ event: NSEvent) {
        clicks.append((event.timestamp, Self.globalPoint()))
    }

    /// Cocoa screen coordinates (origin bottom-left of the primary screen) -> CG global (origin top-left).
    private static func globalPoint() -> CGPoint {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }
}

enum Keystrokes {
    /// Asks for the Accessibility permission (needed to see shortcuts pressed in other apps).
    static func ensurePermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var isAllowed: Bool { AXIsProcessTrusted() }
}
