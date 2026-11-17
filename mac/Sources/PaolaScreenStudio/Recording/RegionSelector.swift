import AppKit
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum RegionMath {
    static let minimumSide: CGFloat = 64

    /// Rectangle spanned by a drag, clamped to `bounds`.
    static func rect(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).intersection(bounds).integral
    }

    static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.width >= minimumSide && rect.height >= minimumSide
    }
}

/// Full-screen overlay to drag out the capture area, then start. Returns the area in display
/// points (origin top-left of that display), or nil when cancelled.
@MainActor
enum RegionSelector {
    static func select(on screen: NSScreen, initial: CGRect?) async -> CGRect? {
        let state = RegionSelectionState(rect: initial)
        let window = FloatingPanel(frame: screen.frame, level: .statusBar)

        return await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (CGRect?) -> Void = { rect in
                guard !resumed else { return }
                resumed = true
                window.orderOut(nil)
                window.contentView = nil
                continuation.resume(returning: rect.flatMap { RegionMath.isUsable($0) ? $0 : nil })
            }
            window.onCancel = { finish(nil) }
            window.onConfirm = { finish(state.rect) }
            window.host(RegionSelectionView(state: state, finish: finish))
            window.setFrame(screen.frame, display: true)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
final class RegionSelectionState: ObservableObject {
    @Published var rect: CGRect?

    init(rect: CGRect?) { self.rect = rect }
}

private struct RegionSelectionView: View {
    @ObservedObject var state: RegionSelectionState
    let finish: (CGRect?) -> Void
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(bounds)
                    if let rect = state.rect { path.addRect(rect) }
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let start = dragStart ?? value.startLocation
                            dragStart = start
                            state.rect = RegionMath.rect(from: start, to: value.location, in: bounds)
                        }
                        .onEnded { _ in dragStart = nil }
                )

                if let rect = state.rect {
                    Rectangle()
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)

                    VStack(spacing: 10) {
                        Text("\(Int(rect.width)) × \(Int(rect.height))")
                            .font(.system(.callout, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                        HStack(spacing: 10) {
                            Button(tr("cancel")) { finish(nil) }
                                .buttonStyle(.bordered)
                            StartRecordingButton { finish(rect) }
                                .disabled(!RegionMath.isUsable(rect))
                        }
                    }
                    .fixedSize()
                    .position(
                        x: min(max(rect.midX, 220), bounds.width - 220),
                        y: rect.maxY + 110 < bounds.height ? rect.maxY + 60 : max(rect.minY - 60, 60)
                    )
                } else {
                    Text(tr("area.instructions"))
                        .font(.title3)
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .frame(width: bounds.width, height: bounds.height)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
    }
}
