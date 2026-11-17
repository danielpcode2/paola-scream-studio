import AppKit
import SwiftUI

/// On-screen pickers for "Display" and "Window" recording targets.
@MainActor
enum TargetPicker {
    /// One overlay per screen with the display name and a start button. Esc cancels.
    static func pickDisplay() async -> CGDirectDisplayID? {
        await withCheckedContinuation { continuation in
            var panels: [FloatingPanel] = []
            var resumed = false
            let finish: (CGDirectDisplayID?) -> Void = { id in
                guard !resumed else { return }
                resumed = true
                panels.forEach { $0.orderOut(nil); $0.contentView = nil }
                continuation.resume(returning: id)
            }
            for screen in NSScreen.screens {
                guard let id = screen.displayID else { continue }
                let panel = FloatingPanel(frame: screen.frame, level: .statusBar)
                panel.onCancel = { finish(nil) }
                panel.onConfirm = { finish(id) }
                panel.host(DisplayPickerView(screen: screen, start: { finish(id) }, cancel: { finish(nil) }))
                panel.setFrame(screen.frame, display: true)
                panels.append(panel)
                panel.orderFrontRegardless()
            }
            NSApp.activate()
            (panels.first { $0.screen == NSScreen.current } ?? panels.first)?.makeKey()
            if panels.isEmpty { finish(nil) }
        }
    }

    /// Hover to highlight a window, click to select it, then start. Esc cancels.
    static func pickWindow() async -> CGWindowID? {
        let state = WindowPickerState(candidates: WindowCandidate.onScreen())
        return await withCheckedContinuation { continuation in
            var panels: [FloatingPanel] = []
            var resumed = false
            let finish: (CGWindowID?) -> Void = { id in
                guard !resumed else { return }
                resumed = true
                panels.forEach { $0.orderOut(nil); $0.contentView = nil }
                continuation.resume(returning: id)
            }
            for screen in NSScreen.screens {
                let panel = FloatingPanel(frame: screen.frame, level: .statusBar)
                panel.onCancel = { finish(nil) }
                panel.onConfirm = { if let id = state.selected?.id { finish(id) } }
                panel.host(WindowPickerView(screenFrame: screen.cgFrame, state: state, start: finish, cancel: { finish(nil) }))
                panel.setFrame(screen.frame, display: true)
                panels.append(panel)
                panel.orderFrontRegardless()
            }
            NSApp.activate()
            (panels.first { $0.screen == NSScreen.current } ?? panels.first)?.makeKey()
        }
    }
}

private struct DisplayPickerView: View {
    let screen: NSScreen
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            VStack(spacing: 6) {
                Text(screen.localizedName)
                    .font(.system(size: 52, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("\(Int(screen.frame.width))×\(Int(screen.frame.height)) • \(screen.maximumFramesPerSecond)FPS")
                    .font(.title3.weight(.medium))
                    .padding(.bottom, 26)
                StartRecordingButton(action: start)
                Button(tr("cancel"), action: cancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 12)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 8)
        }
        .ignoresSafeArea()
    }
}

struct WindowCandidate: Identifiable, Equatable {
    let id: CGWindowID
    /// CG global coordinates.
    let frame: CGRect
    let appName: String
    let title: String

    /// Normal on-screen windows of other apps, front to back.
    static func onScreen() -> [WindowCandidate] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 80, frame.height >= 60
            else { return nil }
            return WindowCandidate(
                id: id,
                frame: frame,
                appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                title: entry[kCGWindowName as String] as? String ?? ""
            )
        }
    }
}

@MainActor
final class WindowPickerState: ObservableObject {
    let candidates: [WindowCandidate]
    @Published var hovered: WindowCandidate?
    @Published var selected: WindowCandidate?

    init(candidates: [WindowCandidate]) { self.candidates = candidates }

    func candidate(at point: CGPoint) -> WindowCandidate? {
        candidates.first { $0.frame.contains(point) }
    }
}

private struct WindowPickerView: View {
    let screenFrame: CGRect
    @ObservedObject var state: WindowPickerState
    let start: (CGWindowID?) -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let point) = phase {
                        state.hovered = state.candidate(at: global(point))
                    }
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    state.selected = state.candidate(at: global(point))
                }

            if let window = state.selected ?? state.hovered {
                let rect = local(window.frame)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.recordAccent.opacity(state.selected == window ? 0.25 : 0.15))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.recordAccent, lineWidth: 3))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }

            if let window = state.selected {
                let rect = local(window.frame)
                VStack(spacing: 12) {
                    Text(window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                    StartRecordingButton { start(window.id) }
                }
                .frame(maxWidth: 520)
                .fixedSize()
                .position(x: rect.midX, y: rect.midY)
            } else {
                Text(tr("window.instructions"))
                    .font(.title3)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .position(x: screenFrame.width / 2, y: 80)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    private func global(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + screenFrame.minX, y: point.y + screenFrame.minY)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}
