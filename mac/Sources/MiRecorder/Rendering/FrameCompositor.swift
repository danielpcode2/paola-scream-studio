import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText

/// Cursor bitmap drawn on top of the recording (the capture itself hides the real cursor).
struct CursorSprite: @unchecked Sendable {
    let image: CIImage
    /// Hot spot in image pixels, origin top-left.
    let hotSpot: CGPoint

    @MainActor
    static func systemArrow() -> CursorSprite? {
        let cursor = NSCursor.arrow
        let nsImage = cursor.image
        guard nsImage.size.width > 0 else { return nil }
        // Ask for a large rect so AppKit picks the sharpest representation.
        var rect = CGRect(origin: .zero, size: CGSize(width: nsImage.size.width * 4, height: nsImage.size.height * 4))
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let scale = CGFloat(cg.width) / nsImage.size.width
        return CursorSprite(
            image: CIImage(cgImage: cg),
            hotSpot: CGPoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale)
        )
    }

    /// Places the sprite so its hot spot lands on `tip` (CoreImage coordinates, origin bottom-left).
    func placed(tip: CGPoint, height: CGFloat) -> CIImage {
        let s = height / image.extent.height
        let hx = hotSpot.x * s
        let hy = (image.extent.height - hotSpot.y) * s
        return image.transformed(
            by: CGAffineTransform(translationX: tip.x - hx, y: tip.y - hy).scaledBy(x: s, y: s)
        )
    }
}

/// Desktop wallpaper URL, captured on the main thread for renderers running elsewhere.
enum Wallpaper {
    nonisolated(unsafe) static var currentURL: URL?

    @MainActor
    static func refresh() {
        currentURL = (NSScreen.main ?? NSScreen.screens.first).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }
}

/// When the cursor should be visible if "hide when idle" is on.
struct CursorActivity: Sendable {
    private let activityTimes: [Double]
    let delay: Double

    init(track: CursorTrack, delay: Double = 1.5) {
        var times = track.clicks.map(\.t)
        var previous: CursorSample?
        for sample in track.samples.sorted(by: { $0.t < $1.t }) {
            if let previous, hypot(sample.x - previous.x, sample.y - previous.y) > 0.0015 {
                times.append(sample.t)
            }
            previous = sample
        }
        if let first = track.samples.first { times.append(first.t) }
        activityTimes = times.sorted()
        self.delay = delay
    }

    /// 1 = visible, fading to 0 after `delay` seconds without movement or clicks.
    func alpha(at t: Double) -> Double {
        var low = 0, high = activityTimes.count
        while low < high {
            let mid = (low + high) / 2
            if activityTimes[mid] <= t { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return 1 }
        let idle = t - activityTimes[low - 1]
        return idle < delay ? 1 : max(0, 1 - (idle - delay) / 0.3)
    }
}

/// Renders one output frame of the edited video.
///
/// Recording space (zooms with the video): blur zones, spotlight, boxes, arrows, click rings, cursor.
/// Canvas space: background, window frame, text, keystrokes, camera, intro/outro cards.
final class FrameCompositor: @unchecked Sendable {
    let sourceSize: CGSize
    let canvasSize: CGSize
    let outputSize: CGSize
    /// Camera bubble center and radius in canvas coordinates (origin bottom-left), default layout.
    let cameraCenter: CGPoint
    let cameraRadius: CGFloat
    var needsPersonMask: Bool { settings.showCamera && settings.cameraBlurBackground }

    private let settings: EditSettings
    private let timeMap: TimeMap
    private let cursorPath: CursorPath?
    private let cameraPath: CursorPath?
    private let activity: CursorActivity?
    private let clicks: [CursorSample]
    private let keystrokes: [KeyStroke]
    private let sprite: CursorSprite?
    private let outputScale: CGFloat

    private let outerRect: CGRect
    private let videoRect: CGRect
    private let titleBar: CIImage?
    private let background: CIImage
    private let shadow: CIImage?
    private let mask: CIImage
    private let dot: CIImage?
    private let halo: CIImage?
    private let annotationImages: [UUID: CIImage]
    private let keyImages: [String: CIImage]
    private let introCard: CIImage?
    private let outroCard: CIImage?

    init(
        sourceSize: CGSize,
        cursor: CursorTrack,
        settings: EditSettings,
        sprite: CursorSprite?,
        keystrokes: [KeyStroke] = [],
        timeMap: TimeMap? = nil,
        outputScale: CGFloat = 1
    ) {
        self.sourceSize = sourceSize
        self.settings = settings
        self.timeMap = timeMap ?? .identity(duration: .greatestFiniteMagnitude)
        self.sprite = settings.showCursor ? sprite : nil
        self.cursorPath = CursorPath(samples: cursor.samples, smoothing: settings.cursorSmoothing)
        // The camera follows a much calmer path than the cursor so zooms do not jitter.
        self.cameraPath = CursorPath(samples: cursor.samples, smoothing: max(0.92, settings.cursorSmoothing))
        self.activity = settings.hideIdleCursor ? CursorActivity(track: cursor) : nil
        self.clicks = cursor.clicks
        self.keystrokes = settings.showKeystrokes ? keystrokes.sorted { $0.t < $1.t } : []

        let canvas = settings.aspect.canvasSize(for: sourceSize)
        canvasSize = canvas
        self.outputScale = min(max(outputScale, 0.01), 1)
        outputSize = CGSize(
            width: CanvasAspect.even(canvas.width * self.outputScale),
            height: CanvasAspect.even(canvas.height * self.outputScale)
        )
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let shortSide = min(canvas.width, canvas.height)

        // Layout: video (+ optional title bar) fitted inside the padded canvas.
        let barFactor: CGFloat = settings.windowFrame == .none ? 0 : 0.055
        let inset = settings.padding * shortSide
        let available = canvasRect.insetBy(dx: inset, dy: inset)
        let contentHeight = sourceSize.height * (1 + barFactor)
        let k = min(available.width / sourceSize.width, available.height / contentHeight)
        let outer = CGRect(
            x: (canvas.width - sourceSize.width * k) / 2,
            y: (canvas.height - contentHeight * k) / 2,
            width: sourceSize.width * k,
            height: contentHeight * k
        )
        outerRect = outer
        let barHeight = sourceSize.height * barFactor * k
        videoRect = CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: outer.height - barHeight)
        titleBar = barHeight > 0
            ? Self.titleBar(width: outer.width, height: barHeight, dark: settings.windowFrame == .dark)?
                .transformed(by: CGAffineTransform(translationX: outer.minX, y: outer.maxY - barHeight))
            : nil

        let radius = settings.cornerRadius * min(outer.width, outer.height)
        let rounded = CIFilter.roundedRectangleGenerator()
        rounded.extent = outer
        rounded.radius = Float(radius)
        rounded.color = .white
        mask = rounded.outputImage ?? CIImage(color: .white).cropped(to: outer)

        background = Self.background(settings, canvas: canvasRect)
        if settings.shadow > 0.01 {
            let blur = shortSide * 0.025
            let shape = CIFilter.roundedRectangleGenerator()
            shape.extent = outer
            shape.radius = Float(radius)
            shape.color = CIColor(red: 0, green: 0, blue: 0, alpha: 0.55 * settings.shadow)
            shadow = shape.outputImage?
                .applyingGaussianBlur(sigma: blur)
                .transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.5))
                .cropped(to: canvasRect)
        } else {
            shadow = nil
        }

        cameraRadius = settings.cameraSize * shortSide / 2
        cameraCenter = Self.bubbleCenter(radius: cameraRadius, corner: settings.cameraCorner, in: outer, shortSide: shortSide)

        // Cursor styles.
        let cursorHeight = sourceSize.height * 0.016 * settings.cursorScale
        dot = settings.cursorStyle == .dot ? Self.circle(diameter: cursorHeight * 1.1, fill: CGColor(gray: 1, alpha: 0.95), stroke: CGColor(gray: 0, alpha: 0.6)) : nil
        halo = settings.cursorStyle == .halo ? Self.circle(diameter: cursorHeight * 2.6, fill: CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.38), stroke: nil) : nil

        // Pre-rendered annotations and keystroke labels.
        var images: [UUID: CIImage] = [:]
        for annotation in settings.annotations {
            if let image = Self.annotationImage(annotation, sourceSize: sourceSize, videoRect: videoRect) {
                images[annotation.id] = image
            }
        }
        annotationImages = images
        let keyFont = max(videoRect.height * 0.045, 10)
        var keys: [String: CIImage] = [:]
        for label in Set(self.keystrokes.map(\.label)) {
            keys[label] = Drawing.text(label, fontSize: keyFont, color: CGColor(gray: 1, alpha: 1), background: CGColor(gray: 0.08, alpha: 0.82), bold: true)
        }
        keyImages = keys

        let darkText = Self.prefersDarkText(settings)
        introCard = settings.intro.enabled ? Self.titleCard(settings.intro, canvas: canvas, darkText: darkText) : nil
        outroCard = settings.outro.enabled ? Self.titleCard(settings.outro, canvas: canvas, darkText: darkText) : nil
    }

    // MARK: Render

    func render(source: CIImage?, camera: CIImage? = nil, cameraMask: CIImage? = nil, at editedTime: Double) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let introEnd = timeMap.intro
        let outroStart = timeMap.intro + timeMap.contentDuration

        var output: CIImage
        if timeMap.isIntro(editedTime) {
            let alpha = min(1, max(0, (introEnd - editedTime) / 0.4))
            output = card(introCard, alpha: alpha)
        } else if timeMap.isOutro(editedTime) {
            let alpha = min(1, max(0, (editedTime - outroStart) / 0.4))
            output = card(outroCard, alpha: alpha)
        } else {
            let time = timeMap.source(atEdited: editedTime)
            var foreground = renderContent(source: source, camera: camera, cameraMask: cameraMask, time: time)
            // Fade the video in after the intro and out before the outro.
            var alpha = 1.0
            if introEnd > 0 { alpha = min(alpha, (editedTime - introEnd) / 0.4) }
            if timeMap.outro > 0 { alpha = min(alpha, (outroStart - editedTime) / 0.4) }
            foreground = faded(foreground, max(0, min(1, alpha)))
            output = foreground.composited(over: background)
        }
        output = output.cropped(to: canvasRect)
        if outputScale < 1 {
            output = output.transformed(by: CGAffineTransform(scaleX: outputScale, y: outputScale))
        }
        return output.cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    private func card(_ card: CIImage?, alpha: Double) -> CIImage {
        guard let card else { return background }
        return faded(card, alpha).composited(over: background)
    }

    /// Everything except the background, for one recording time.
    private func renderContent(source: CIImage?, camera: CIImage?, cameraMask: CIImage?, time: Double) -> CIImage {
        let W = sourceSize.width
        let H = sourceSize.height
        let sourceRect = CGRect(origin: .zero, size: sourceSize)
        var frame = source.map { $0.transformed(by: CGAffineTransform(translationX: -$0.extent.minX, y: -$0.extent.minY)) }
            ?? CIImage(color: .black).cropped(to: sourceRect)

        // Annotations drawn on the recording (they zoom with it).
        for annotation in settings.annotations where annotation.kind != .text {
            let alpha = SpanRamp.progress(at: time, start: annotation.start, end: annotation.end, ramp: 0.25)
            guard alpha > 0.01 else { continue }
            let rect = pixelRect(annotation.rect)
            switch annotation.kind {
            case .blur:
                let scale = max(H * 0.018, 4)
                let blurred = frame.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(cgPoint: rect.origin)])
                    .applyingGaussianBlur(sigma: scale * 0.6)
                    .cropped(to: rect)
                frame = faded(blurred, alpha).composited(over: frame)
            case .spotlight:
                let dark = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.6 * alpha)).cropped(to: sourceRect)
                let hole = CIFilter.roundedRectangleGenerator()
                hole.extent = rect
                hole.radius = Float(min(rect.width, rect.height) * 0.08)
                hole.color = .white
                let overlay = CIImage(color: .clear).cropped(to: sourceRect).applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: dark,
                    kCIInputMaskImageKey: hole.outputImage ?? CIImage.empty(),
                ])
                frame = overlay.composited(over: frame)
            case .box, .arrow:
                if let image = annotationImages[annotation.id] { frame = faded(image, alpha).composited(over: frame) }
            case .text:
                break
            }
        }

        if settings.showClickHighlights {
            let radius = H * 0.03
            for click in clicks where time >= click.t && time - click.t < 0.4 {
                let progress = (time - click.t) / 0.4
                let ring = CIFilter.radialGradient()
                ring.center = CGPoint(x: click.x * W, y: (1 - click.y) * H)
                ring.radius0 = Float(radius * progress * 0.6)
                ring.radius1 = Float(radius * progress + 1)
                ring.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.55 * (1 - progress))
                ring.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
                if let image = ring.outputImage {
                    frame = image.cropped(to: CGRect(x: ring.center.x - radius - 2, y: ring.center.y - radius - 2, width: radius * 2 + 4, height: radius * 2 + 4))
                        .composited(over: frame)
                }
            }
        }

        if settings.showCursor, let path = cursorPath {
            let alpha = activity?.alpha(at: time) ?? 1
            if alpha > 0.01 {
                let p = path.position(at: time)
                let tip = CGPoint(x: p.x * W, y: (1 - p.y) * H)
                if let image = cursorImage(tip: tip) { frame = faded(image, alpha).composited(over: frame) }
            }
        }
        frame = frame.cropped(to: sourceRect)

        let zoomState = ZoomTimeline.state(at: time, segments: settings.zoomSegments)
        let zoom = zoomState.scale
        if zoomState.style == .loupe, zoomState.progress > 0.01 {
            frame = loupe(frame, state: zoomState, time: time)
        } else if zoom > 1.001 {
            let target = zoomState.focus ?? cameraPath?.position(at: time) ?? CGPoint(x: 0.5, y: 0.5)
            let focus = ZoomTimeline.clampedCenter(target, scale: zoom)
            let transform = CGAffineTransform(translationX: W / 2, y: H / 2)
                .scaledBy(x: zoom, y: zoom)
                .translatedBy(x: -focus.x * W, y: -(1 - focus.y) * H)
            frame = frame.clampedToExtent().transformed(by: transform).cropped(to: sourceRect)
        }

        // Place the recording (and title bar) on the canvas with rounded corners.
        frame = frame.transformed(by: CGAffineTransform(scaleX: videoRect.width / W, y: videoRect.height / H)
            .concatenating(CGAffineTransform(translationX: videoRect.minX, y: videoRect.minY)))
        if let titleBar { frame = titleBar.composited(over: frame) }
        frame = frame.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
        var output = shadow.map { frame.composited(over: $0) } ?? frame

        output = renderCamera(camera, mask: cameraMask, time: time, over: output)

        // Canvas-space overlays: text annotations and keystrokes.
        for annotation in settings.annotations where annotation.kind == .text {
            let alpha = SpanRamp.progress(at: time, start: annotation.start, end: annotation.end, ramp: 0.25)
            if alpha > 0.01, let image = annotationImages[annotation.id] {
                output = faded(image, alpha).composited(over: output)
            }
        }
        if let key = keystrokes.last(where: { $0.t <= time && time - $0.t < 1.2 }), let image = keyImages[key.label] {
            let age = time - key.t
            let alpha = min(1, age / 0.08, (1.2 - age) / 0.25)
            let placed = image.transformed(by: CGAffineTransform(
                translationX: videoRect.midX - image.extent.width / 2,
                y: videoRect.minY + videoRect.height * 0.06
            ))
            output = faded(placed, alpha).composited(over: output)
        }
        return output
    }

    // MARK: Loupe

    /// Round magnifier centred on the cursor (or the fixed focus); grows in and out with the zoom ramp.
    private func loupe(_ frame: CIImage, state: ZoomTimeline.State, time: Double) -> CIImage {
        let W = sourceSize.width, H = sourceSize.height
        let point = state.focus ?? cursorPath?.position(at: time) ?? CGPoint(x: 0.5, y: 0.5)
        let center = CGPoint(x: point.x * W, y: (1 - point.y) * H)
        let radius = H * 0.17 * state.progress
        guard radius > 2 else { return frame }
        let magnification = state.segmentScale
        let magnified = frame.clampedToExtent().transformed(by: CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: magnification, y: magnification)
            .translatedBy(x: -center.x, y: -center.y))
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: disc(center: center, radius: radius, color: .white),
            ])
        let border = max(2, radius * 0.04)
        let ring = disc(center: center, radius: radius + border, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        let shadow = disc(center: center, radius: radius + border, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.4))
            .applyingGaussianBlur(sigma: radius * 0.12)
            .transformed(by: CGAffineTransform(translationX: 0, y: -radius * 0.05))
        return magnified.composited(over: ring).composited(over: shadow).composited(over: frame)
            .cropped(to: CGRect(origin: .zero, size: sourceSize))
    }

    // MARK: Cursor

    private func cursorImage(tip: CGPoint) -> CIImage? {
        let height = sourceSize.height * 0.016 * settings.cursorScale
        func centered(_ image: CIImage?) -> CIImage? {
            image.map { $0.transformed(by: CGAffineTransform(translationX: tip.x - $0.extent.width / 2, y: tip.y - $0.extent.height / 2)) }
        }
        switch settings.cursorStyle {
        case .dot:
            return centered(dot)
        case .halo:
            let ring = centered(halo)
            let arrow = sprite?.placed(tip: tip, height: height)
            if let arrow, let ring { return arrow.composited(over: ring) }
            return arrow ?? ring
        case .arrow:
            return sprite?.placed(tip: tip, height: height)
        }
    }

    // MARK: Camera

    private func renderCamera(_ camera: CIImage?, mask: CIImage?, time: Double, over output: CIImage) -> CIImage {
        guard settings.showCamera, var camera else { return output }
        if let mask {
            // Keep the person sharp, blur the room behind.
            let extent = camera.extent
            let blurred = camera.clampedToExtent().applyingGaussianBlur(sigma: min(extent.width, extent.height) * 0.035).cropped(to: extent)
            camera = camera.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: blurred,
                kCIInputMaskImageKey: mask.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)),
            ])
        }
        if settings.mirrorCamera {
            let extent = camera.extent
            camera = camera.transformed(by: CGAffineTransform(translationX: extent.maxX + extent.minX, y: 0).scaledBy(x: -1, y: 1))
        }

        var layout: CameraLayout?
        var progress = 0.0
        for segment in settings.cameraLayouts {
            let value = SpanRamp.progress(at: time, start: segment.start, end: segment.end, ramp: 0.35)
            if value > progress {
                progress = value
                layout = segment.layout
            }
        }

        var radius = cameraRadius
        var bubbleAlpha = 1.0
        switch layout {
        case .large: radius *= 1 + progress
        case .hidden, .fullscreen: bubbleAlpha = 1 - progress
        case nil: break
        }
        var result = output
        if bubbleAlpha > 0.01, radius > 1 {
            let center = layout == .large
                ? Self.bubbleCenter(radius: radius, corner: settings.cameraCorner, in: outerRect, shortSide: min(canvasSize.width, canvasSize.height))
                : cameraCenter
            result = faded(cameraBubble(camera, center: center, radius: radius), bubbleAlpha).composited(over: result)
        }
        if layout == .fullscreen, progress > 0.01 {
            let extent = camera.extent
            let scale = max(canvasSize.width / extent.width, canvasSize.height / extent.height)
            let placed = camera
                .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: (canvasSize.width - extent.width * scale) / 2,
                    y: (canvasSize.height - extent.height * scale) / 2
                ))
                .cropped(to: CGRect(origin: .zero, size: canvasSize))
            result = faded(placed, progress).composited(over: result)
        }
        return result
    }

    /// Center-square crop of the (already mirrored) camera frame, masked to a circle with border and shadow.
    private func cameraBubble(_ camera: CIImage, center: CGPoint, radius r: CGFloat) -> CIImage {
        let extent = camera.extent
        let side = min(extent.width, extent.height)
        guard side > 0 else { return CIImage.empty() }
        let s = r * 2 / side
        let image = camera
            .cropped(to: CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -(extent.midX - side / 2), y: -(extent.midY - side / 2)))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: center.x - r, y: center.y - r))
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: bubbleShape(center: center, radius: r, color: .white),
            ])
        let border = max(1, r * 0.012)
        let ring = bubbleShape(center: center, radius: r + border, color: settings.cameraBorderColor.ciColor)
        let shadow = bubbleShape(center: center, radius: r + border, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35 * max(settings.shadow, 0.3)))
            .applyingGaussianBlur(sigma: r * 0.12)
            .transformed(by: CGAffineTransform(translationX: 0, y: -r * 0.06))
        return image.composited(over: ring).composited(over: shadow)
    }

    /// Camera outline (circle, rounded square or square) filled with a color.
    private func bubbleShape(center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage {
        let shape = settings.cameraShape
        guard shape != .circle else { return disc(center: center, radius: radius, color: color) }
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        generator.radius = Float(radius * shape.cornerFraction)
        generator.color = color
        return generator.outputImage ?? CIImage.empty()
    }

    private func disc(center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(radius - 1)
        gradient.radius1 = Float(radius)
        gradient.color0 = color
        gradient.color1 = CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0)
        let box = CGRect(x: center.x - radius - 1, y: center.y - radius - 1, width: radius * 2 + 2, height: radius * 2 + 2)
        return (gradient.outputImage ?? CIImage.empty()).cropped(to: box)
    }

    private static func bubbleCenter(radius: CGFloat, corner: CameraCorner, in rect: CGRect, shortSide: CGFloat) -> CGPoint {
        let margin = shortSide * 0.03 + radius
        let left = rect.minX + margin, right = rect.maxX - margin
        let bottom = rect.minY + margin, top = rect.maxY - margin
        return switch corner {
        case .bottomRight: CGPoint(x: right, y: bottom)
        case .bottomLeft: CGPoint(x: left, y: bottom)
        case .topRight: CGPoint(x: right, y: top)
        case .topLeft: CGPoint(x: left, y: top)
        }
    }

    // MARK: Helpers

    /// Normalized rect (origin top-left) -> recording pixels (CoreImage coordinates).
    private func pixelRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * sourceSize.width,
            y: (1 - rect.maxY) * sourceSize.height,
            width: rect.width * sourceSize.width,
            height: rect.height * sourceSize.height
        )
    }

    private func faded(_ image: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
    }

    private static func background(_ settings: EditSettings, canvas: CGRect) -> CIImage {
        var image: CIImage?
        switch settings.backgroundKind {
        case .color:
            image = CIImage(color: settings.backgroundColor.ciColor)
        case .image:
            image = settings.backgroundImagePath.flatMap { CIImage(contentsOf: URL(fileURLWithPath: $0)) }.map { aspectFill($0, canvas) }
        case .wallpaper:
            image = Wallpaper.currentURL.flatMap { CIImage(contentsOf: $0) }.map { aspectFill($0, canvas) }
        case .gradient:
            break
        }
        if image == nil {
            let gradient = CIFilter.linearGradient()
            gradient.point0 = CGPoint(x: 0, y: canvas.height)
            gradient.point1 = CGPoint(x: canvas.width, y: 0)
            gradient.color0 = settings.background.start.ciColor
            gradient.color1 = settings.background.end.ciColor
            image = gradient.outputImage
        }
        var result = (image ?? CIImage(color: .black)).cropped(to: canvas)
        if settings.backgroundBlur > 0.01 {
            result = result.clampedToExtent()
                .applyingGaussianBlur(sigma: settings.backgroundBlur * min(canvas.width, canvas.height) * 0.04)
                .cropped(to: canvas)
        }
        return result
    }

    private static func aspectFill(_ image: CIImage, _ canvas: CGRect) -> CIImage {
        let extent = image.extent
        let scale = max(canvas.width / extent.width, canvas.height / extent.height)
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (canvas.width - extent.width * scale) / 2, y: (canvas.height - extent.height * scale) / 2))
    }

    private static func prefersDarkText(_ settings: EditSettings) -> Bool {
        func luminance(_ c: RGBAColor) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
        switch settings.backgroundKind {
        case .gradient: return (luminance(settings.background.start) + luminance(settings.background.end)) / 2 > 0.62
        case .color: return luminance(settings.backgroundColor) > 0.62
        case .image, .wallpaper: return false
        }
    }

    private static func titleCard(_ card: TitleCard, canvas: CGSize, darkText: Bool) -> CIImage? {
        let shortSide = min(canvas.width, canvas.height)
        let color = darkText ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
        let secondary = darkText ? CGColor(gray: 0.08, alpha: 0.75) : CGColor(gray: 1, alpha: 0.8)
        let title = card.title.isEmpty ? nil : Drawing.text(card.title, fontSize: shortSide * 0.075, color: color, background: nil, bold: true, shadow: !darkText)
        let subtitle = card.subtitle.isEmpty ? nil : Drawing.text(card.subtitle, fontSize: shortSide * 0.035, color: secondary, background: nil, bold: false, shadow: !darkText)
        let gap = shortSide * 0.02
        let parts = [title, subtitle].compactMap { $0 }
        let totalHeight = parts.reduce(0) { $0 + $1.extent.height } + (parts.count > 1 ? gap : 0)
        var y = (canvas.height + totalHeight) / 2
        var result = CIImage.empty()
        for image in parts {
            y -= image.extent.height
            result = image.transformed(by: CGAffineTransform(translationX: (canvas.width - image.extent.width) / 2, y: y)).composited(over: result)
            y -= gap
        }
        return result
    }

    private static func titleBar(width: CGFloat, height: CGFloat, dark: Bool) -> CIImage? {
        Drawing.image(width: Int(width.rounded(.up)), height: Int(height.rounded(.up))) { context in
            context.setFillColor(dark ? CGColor(gray: 0.17, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(dark ? CGColor(gray: 0, alpha: 0.5) : CGColor(gray: 0, alpha: 0.12))
            context.fill(CGRect(x: 0, y: 0, width: width, height: max(1, height * 0.02)))
            let r = height * 0.21
            let colors = [
                CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1),
                CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
                CGColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1),
            ]
            for (index, color) in colors.enumerated() {
                context.setFillColor(color)
                let cx = height * 0.62 + CGFloat(index) * r * 3.3
                context.fillEllipse(in: CGRect(x: cx - r, y: height / 2 - r, width: r * 2, height: r * 2))
            }
        }
    }

    private static func circle(diameter: CGFloat, fill: CGColor, stroke: CGColor?) -> CIImage? {
        let size = Int(diameter.rounded(.up)) + 4
        return Drawing.image(width: size, height: size) { context in
            let rect = CGRect(x: 2, y: 2, width: diameter, height: diameter)
            context.setFillColor(fill)
            context.fillEllipse(in: rect)
            if let stroke {
                context.setStrokeColor(stroke)
                context.setLineWidth(max(1, diameter * 0.08))
                context.strokeEllipse(in: rect.insetBy(dx: diameter * 0.04, dy: diameter * 0.04))
            }
        }
    }

    private static func annotationImage(_ annotation: Annotation, sourceSize: CGSize, videoRect: CGRect) -> CIImage? {
        let W = sourceSize.width, H = sourceSize.height
        let color = CGColor(red: annotation.color.r, green: annotation.color.g, blue: annotation.color.b, alpha: annotation.color.a)
        switch annotation.kind {
        case .text:
            guard !annotation.text.isEmpty,
                  let image = Drawing.text(annotation.text, fontSize: videoRect.height * 0.045 * annotation.size, color: color, background: CGColor(gray: 0.05, alpha: 0.7), bold: true)
            else { return nil }
            let center = CGPoint(x: videoRect.minX + annotation.rect.midX * videoRect.width, y: videoRect.maxY - annotation.rect.midY * videoRect.height)
            return image.transformed(by: CGAffineTransform(translationX: center.x - image.extent.width / 2, y: center.y - image.extent.height / 2))
        case .box:
            let line = H * 0.005 * annotation.size
            let rect = CGRect(x: annotation.rect.minX * W, y: (1 - annotation.rect.maxY) * H, width: annotation.rect.width * W, height: annotation.rect.height * H)
            let canvas = rect.insetBy(dx: -line, dy: -line)
            return Drawing.image(width: Int(canvas.width.rounded(.up)), height: Int(canvas.height.rounded(.up))) { context in
                context.setStrokeColor(color)
                context.setLineWidth(line)
                let inner = CGRect(x: line, y: line, width: rect.width, height: rect.height).insetBy(dx: line / 2, dy: line / 2)
                let corner = min(inner.width, inner.height) * 0.08
                context.addPath(CGPath(roundedRect: inner, cornerWidth: corner, cornerHeight: corner, transform: nil))
                context.strokePath()
            }?.transformed(by: CGAffineTransform(translationX: canvas.minX, y: canvas.minY))
        case .arrow:
            let line = H * 0.006 * annotation.size
            let from = CGPoint(x: annotation.from.x * W, y: (1 - annotation.from.y) * H)
            let to = CGPoint(x: annotation.to.x * W, y: (1 - annotation.to.y) * H)
            let head = line * 4.5
            let margin = head + line
            let box = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
                .insetBy(dx: -margin, dy: -margin)
            let angle = atan2(to.y - from.y, to.x - from.x)
            return Drawing.image(width: Int(box.width.rounded(.up)), height: Int(box.height.rounded(.up))) { context in
                let a = CGPoint(x: from.x - box.minX, y: from.y - box.minY)
                let b = CGPoint(x: to.x - box.minX, y: to.y - box.minY)
                let shaftEnd = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
                context.setStrokeColor(color)
                context.setFillColor(color)
                context.setLineWidth(line)
                context.setLineCap(.round)
                context.move(to: a)
                context.addLine(to: shaftEnd)
                context.strokePath()
                context.move(to: b)
                context.addLine(to: CGPoint(x: b.x - cos(angle - 0.45) * head, y: b.y - sin(angle - 0.45) * head))
                context.addLine(to: CGPoint(x: b.x - cos(angle + 0.45) * head, y: b.y - sin(angle + 0.45) * head))
                context.closePath()
                context.fillPath()
            }?.transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
        case .spotlight, .blur:
            return nil
        }
    }
}

/// Off-screen drawing into CoreImage images (CoreGraphics + CoreText only, safe off the main thread).
enum Drawing {
    static func image(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CIImage? {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        draw(context)
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    /// Centered (multi-line) text, optionally on a rounded pill.
    static func text(_ string: String, fontSize: CGFloat, color: CGColor, background: CGColor?, bold: Bool, shadow: Bool = false) -> CIImage? {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer -> CTParagraphStyle in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, CGSize(width: fontSize * 28, height: .greatestFiniteMagnitude), nil
        )
        let padX = background == nil ? fontSize * 0.3 : fontSize * 0.6
        let padY = background == nil ? fontSize * 0.3 : fontSize * 0.35
        let width = ceil(size.width) + padX * 2
        let height = ceil(size.height) + padY * 2
        return image(width: Int(width), height: Int(height)) { context in
            if let background {
                context.setFillColor(background)
                let radius = min(height / 2, fontSize * 0.6)
                context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
            if shadow {
                context.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.04), blur: fontSize * 0.25, color: CGColor(gray: 0, alpha: 0.55))
            }
            let path = CGPath(rect: CGRect(x: padX, y: padY, width: ceil(size.width) + 1, height: ceil(size.height) + 1), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
        }
    }
}
