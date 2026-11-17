import CoreGraphics
import CoreImage
import Foundation
import SwiftUI

/// Cursor position sample. Coordinates are normalized to the recorded display
/// (0...1, origin top-left). `t` is seconds since the recording started.
struct CursorSample: Codable, Equatable, Sendable {
    var t: Double
    var x: Double
    var y: Double
}

struct CursorTrack: Codable, Equatable, Sendable {
    var samples: [CursorSample] = []
    var clicks: [CursorSample] = []
}

struct ZoomSegment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: Double
    var isEnabled = true
    /// Fixed point to zoom into (normalized, origin top-left). nil = follow the cursor.
    var focus: CGPoint?
    /// nil = classic (whole frame zooms).
    var style: ZoomStyle?

    var resolvedStyle: ZoomStyle { style ?? .classic }
}

enum ZoomStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The whole frame zooms in.
    case classic
    /// A round magnifier follows the cursor; the rest of the frame stays as is.
    case loupe

    var id: String { rawValue }
    var icon: String { self == .classic ? "arrow.up.left.and.arrow.down.right.magnifyingglass" : "magnifyingglass.circle" }
}

/// Anything placed on the timeline (seconds of the original recording).
protocol TimelineSpan: Identifiable, Equatable where ID == UUID {
    var id: UUID { get set }
    var start: Double { get set }
    var end: Double { get set }
}

extension ZoomSegment: TimelineSpan {}

/// Removes (`speed == 0`) or speeds up a part of the recording.
struct TimeEdit: Codable, Equatable, Identifiable, Sendable, TimelineSpan {
    var id = UUID()
    var start: Double
    var end: Double
    var speed: Double

    var isCut: Bool { speed <= 0 }
    static let speeds: [Double] = [1.5, 2, 4, 8]
}

enum CameraLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullscreen, large, hidden

    var id: String { rawValue }
}

/// Changes how the camera is shown during part of the recording.
struct CameraLayoutSegment: Codable, Equatable, Identifiable, Sendable, TimelineSpan {
    var id = UUID()
    var start: Double
    var end: Double
    var layout: CameraLayout
}

enum AnnotationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case text, arrow, box, spotlight, blur

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .text: "textformat"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .spotlight: "light.max"
        case .blur: "eye.slash"
        }
    }
}

/// Text, arrow, box, spotlight or blur shown during part of the recording.
/// Coordinates are normalized to the recorded frame (origin top-left). Text stays the same size
/// when zooming; the other kinds are drawn on the recording, so they zoom with it.
struct Annotation: Codable, Equatable, Identifiable, Sendable, TimelineSpan {
    var id = UUID()
    var start: Double
    var end: Double
    var kind: AnnotationKind
    var rect = CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2)
    var from = CGPoint(x: 0.35, y: 0.65)
    var to = CGPoint(x: 0.55, y: 0.45)
    var text = ""
    var color = RGBAColor(1, 0.27, 0.23)
    /// Text size / stroke width multiplier.
    var size: Double = 1
}

/// Keyboard shortcut pressed while recording (only combinations with ⌘, ⌃ or ⌥).
struct KeyStroke: Codable, Equatable, Sendable {
    var t: Double
    var label: String
}

enum BackgroundKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case gradient, color, image, wallpaper

    var id: String { rawValue }
}

enum WindowFrameStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, light, dark

    var id: String { rawValue }
}

enum CursorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case arrow, dot, halo

    var id: String { rawValue }
}

struct TitleCard: Codable, Equatable, Sendable {
    var enabled = false
    var title = ""
    var subtitle = ""
    var duration: Double = 2.5
}

struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    var color: Color { Color(red: r, green: g, blue: b, opacity: a) }
    var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .white
        self.init(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    /// Quick picks for the camera border; alpha 0 = no border.
    static let borderPresets: [(key: String, color: RGBAColor)] = [
        ("white", .init(1, 1, 1, 0.95)),
        ("black", .init(0, 0, 0, 0.9)),
        ("purple", .init(0.55, 0.36, 0.96)),
        ("blue", .init(0.2, 0.5, 1)),
        ("green", .init(0.2, 0.78, 0.45)),
        ("orange", .init(1, 0.55, 0.15)),
        ("pink", .init(0.98, 0.35, 0.6)),
        ("none", .init(1, 1, 1, 0)),
    ]
}

struct GradientBackground: Codable, Equatable, Hashable, Sendable {
    var name: String
    var start: RGBAColor
    var end: RGBAColor

    static let presets: [GradientBackground] = [
        .init(name: "Océano", start: .init(0.15, 0.45, 0.95), end: .init(0.45, 0.20, 0.85)),
        .init(name: "Atardecer", start: .init(0.98, 0.55, 0.30), end: .init(0.90, 0.25, 0.50)),
        .init(name: "Bosque", start: .init(0.10, 0.55, 0.45), end: .init(0.55, 0.80, 0.35)),
        .init(name: "Medianoche", start: .init(0.07, 0.08, 0.18), end: .init(0.22, 0.18, 0.40)),
        .init(name: "Lavanda", start: .init(0.80, 0.70, 0.98), end: .init(0.98, 0.78, 0.86)),
        .init(name: "Grafito", start: .init(0.18, 0.18, 0.20), end: .init(0.38, 0.38, 0.42)),
        .init(name: "Menta", start: .init(0.62, 0.95, 0.85), end: .init(0.40, 0.70, 0.95)),
        .init(name: "Blanco", start: .init(0.96, 0.96, 0.97), end: .init(0.86, 0.87, 0.90)),
    ]
}

enum CanvasAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case source, landscape, portrait, square

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source: "Original"
        case .landscape: "16:9"
        case .portrait: "9:16"
        case .square: "1:1"
        }
    }

    /// Output canvas size in pixels, rounded to even values for video encoders.
    func canvasSize(for source: CGSize) -> CGSize {
        let size: CGSize = switch self {
        case .source: source
        case .landscape: CGSize(width: source.width, height: source.width * 9 / 16)
        case .portrait: CGSize(width: source.height * 9 / 16, height: source.height)
        case .square: CGSize(width: source.height, height: source.height)
        }
        return CGSize(width: Self.even(size.width), height: Self.even(size.height))
    }

    static func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
}

/// Outline of the camera bubble.
enum CameraShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case circle, rounded, square

    var id: String { rawValue }
    var title: String { tr("camera.shape.\(rawValue)") }
    var icon: String {
        switch self {
        case .circle: "circle"
        case .rounded: "app"
        case .square: "square"
        }
    }

    /// Corner radius as a fraction of half the side (1 = circle).
    var cornerFraction: CGFloat {
        switch self {
        case .circle: 1
        case .rounded: 0.32
        case .square: 0.06
        }
    }
}

enum CameraCorner: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottomRight, bottomLeft, topRight, topLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottomRight: "↘"
        case .bottomLeft: "↙"
        case .topRight: "↗"
        case .topLeft: "↖"
        }
    }
}

struct EditSettings: Codable, Equatable, Sendable {
    // Background
    var background = GradientBackground.presets[0]
    var backgroundKind: BackgroundKind = .gradient
    var backgroundColor = RGBAColor(0.12, 0.12, 0.14)
    /// Absolute path of a user image (kind `.image`).
    var backgroundImagePath: String?
    /// 0...1
    var backgroundBlur: Double = 0
    // Frame
    /// Fraction of the shorter canvas side used as padding around the video.
    var padding: Double = 0.07
    /// Corner radius as a fraction of the shorter video side.
    var cornerRadius: Double = 0.02
    var shadow: Double = 0.6
    var windowFrame: WindowFrameStyle = .none
    var aspect: CanvasAspect = .source
    // Cursor
    var showCursor = true
    var cursorStyle: CursorStyle = .arrow
    var cursorScale: Double = 1.5
    /// 0 = raw movement, 1 = very smooth.
    var cursorSmoothing: Double = 0.6
    var showClickHighlights = true
    var hideIdleCursor = false
    var clickSound = false
    var showKeystrokes = true
    // Zoom
    var autoZoomScale: Double = 1.8
    var zoomSegments: [ZoomSegment] = []
    // Timeline
    var timeEdits: [TimeEdit] = []
    var annotations: [Annotation] = []
    var trimStart: Double = 0
    var trimEnd: Double?
    // Camera
    var showCamera = true
    /// Bubble diameter as a fraction of the shorter canvas side.
    var cameraSize: Double = 0.24
    var cameraCorner: CameraCorner = .bottomRight
    var cameraShape: CameraShape = .circle
    /// Alpha 0 hides the border.
    var cameraBorderColor = RGBAColor(1, 1, 1, 0.95)
    var mirrorCamera = true
    var cameraBlurBackground = false
    var cameraLayouts: [CameraLayoutSegment] = []
    // Audio
    var recordingVolume: Double = 1
    var normalizeAudio = false
    var noiseReduction = false
    /// File name inside the project folder.
    var musicFile: String?
    var musicVolume: Double = 0.25
    // Intro / outro
    var intro = TitleCard()
    var outro = TitleCard()

    init() {}

    /// Missing keys fall back to defaults so projects saved by older versions keep opening.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        background = try value(.background, d.background)
        backgroundKind = try value(.backgroundKind, d.backgroundKind)
        backgroundColor = try value(.backgroundColor, d.backgroundColor)
        backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        backgroundBlur = try value(.backgroundBlur, d.backgroundBlur)
        padding = try value(.padding, d.padding)
        cornerRadius = try value(.cornerRadius, d.cornerRadius)
        shadow = try value(.shadow, d.shadow)
        windowFrame = try value(.windowFrame, d.windowFrame)
        aspect = try value(.aspect, d.aspect)
        showCursor = try value(.showCursor, d.showCursor)
        cursorStyle = try value(.cursorStyle, d.cursorStyle)
        cursorScale = try value(.cursorScale, d.cursorScale)
        cursorSmoothing = try value(.cursorSmoothing, d.cursorSmoothing)
        showClickHighlights = try value(.showClickHighlights, d.showClickHighlights)
        hideIdleCursor = try value(.hideIdleCursor, d.hideIdleCursor)
        clickSound = try value(.clickSound, d.clickSound)
        showKeystrokes = try value(.showKeystrokes, d.showKeystrokes)
        autoZoomScale = try value(.autoZoomScale, d.autoZoomScale)
        zoomSegments = try value(.zoomSegments, d.zoomSegments)
        timeEdits = try value(.timeEdits, d.timeEdits)
        annotations = try value(.annotations, d.annotations)
        trimStart = try value(.trimStart, d.trimStart)
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        showCamera = try value(.showCamera, d.showCamera)
        cameraSize = try value(.cameraSize, d.cameraSize)
        cameraCorner = try value(.cameraCorner, d.cameraCorner)
        cameraShape = try value(.cameraShape, d.cameraShape)
        cameraBorderColor = try value(.cameraBorderColor, d.cameraBorderColor)
        mirrorCamera = try value(.mirrorCamera, d.mirrorCamera)
        cameraBlurBackground = try value(.cameraBlurBackground, d.cameraBlurBackground)
        cameraLayouts = try value(.cameraLayouts, d.cameraLayouts)
        recordingVolume = try value(.recordingVolume, d.recordingVolume)
        normalizeAudio = try value(.normalizeAudio, d.normalizeAudio)
        noiseReduction = try value(.noiseReduction, d.noiseReduction)
        musicFile = try c.decodeIfPresent(String.self, forKey: .musicFile)
        musicVolume = try value(.musicVolume, d.musicVolume)
        intro = try value(.intro, d.intro)
        outro = try value(.outro, d.outro)
    }

    /// Settings that change the composition itself (timing and audio), not just how frames look.
    struct StructureKey: Equatable {
        let timeEdits: [TimeEdit]
        let clickSound: Bool
        let intro: TitleCard
        let outro: TitleCard
        let recordingVolume: Double
        let normalizeAudio: Bool
        let noiseReduction: Bool
        let musicFile: String?
        let musicVolume: Double
    }

    var structureKey: StructureKey {
        StructureKey(
            timeEdits: timeEdits, clickSound: clickSound, intro: intro, outro: outro,
            recordingVolume: recordingVolume, normalizeAudio: normalizeAudio, noiseReduction: noiseReduction,
            musicFile: musicFile, musicVolume: musicVolume
        )
    }
}

/// Camera recorded alongside the screen. `offset` = seconds after the screen recording
/// started at which the camera file's first frame was captured (may be negative).
struct CameraClip: Codable, Sendable {
    var fileName: String
    var offset: Double
}

struct ProjectData: Codable, Sendable {
    var version = 1
    var createdAt: Date
    var cursor: CursorTrack
    var settings: EditSettings
    var camera: CameraClip?
    /// Screen recording files in order (one per pause/resume). nil = legacy single `recording.mov`.
    var segments: [String]?
    /// Flags created while recording, in seconds on the project timeline.
    var flags: [Double]?
    /// Keyboard shortcuts pressed while recording.
    var keystrokes: [KeyStroke]?

    var screenFiles: [String] { segments ?? ["recording.mov"] }
}

extension EditSettings {
    /// Look only (background, frame, cursor, camera, format): no zooms or trim from a specific recording.
    var styleOnly: EditSettings {
        var copy = self
        copy.zoomSegments = []
        copy.timeEdits = []
        copy.annotations = []
        copy.cameraLayouts = []
        copy.musicFile = nil
        copy.trimStart = 0
        copy.trimEnd = nil
        return copy
    }

    /// Applies a preset's look while keeping this project's timeline edits, music and trim.
    func applyingStyle(_ preset: EditSettings) -> EditSettings {
        var result = preset
        result.zoomSegments = zoomSegments
        result.timeEdits = timeEdits
        result.annotations = annotations
        result.cameraLayouts = cameraLayouts
        result.musicFile = musicFile
        result.trimStart = trimStart
        result.trimEnd = trimEnd
        return result
    }
}
