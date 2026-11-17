import CoreGraphics
import Foundation

struct ExportOptions: Codable, Equatable, Sendable {
    enum Format: String, Codable, CaseIterable, Identifiable, Sendable {
        case mp4, prores, gif

        var id: String { rawValue }
        var label: String {
            switch self {
            case .mp4: "MP4"
            case .prores: "ProRes"
            case .gif: "GIF"
            }
        }
        var fileExtension: String {
            switch self {
            case .mp4: "mp4"
            case .prores: "mov"
            case .gif: "gif"
            }
        }
    }

    enum Resolution: String, Codable, CaseIterable, Identifiable, Sendable {
        case p720, p1080, p4k

        var id: String { rawValue }
        var label: String {
            switch self {
            case .p720: "720p"
            case .p1080: "1080p"
            case .p4k: "4K"
            }
        }
        /// Target length of the canvas' shorter side.
        var shortSide: CGFloat {
            switch self {
            case .p720: 720
            case .p1080: 1080
            case .p4k: 2160
            }
        }
    }

    enum Compression: String, Codable, CaseIterable, Identifiable, Sendable {
        case studio, social, web, webLow

        var id: String { rawValue }
        var label: String { tr("compression.\(rawValue)") }
        var detail: String { tr("compression.\(rawValue).detail") }
        /// Encoded bits per pixel per frame.
        var bitsPerPixel: Double {
            switch self {
            case .studio: 0.30
            case .social: 0.12
            case .web: 0.07
            case .webLow: 0.04
            }
        }
    }

    static let frameRates = [24, 25, 30, 50, 60]
    /// GIFs get large quickly; cap their frame rate and size.
    static let gifMaxFrameRate = 30
    static let gifMaxShortSide: CGFloat = 720

    var format: Format = .mp4
    var fps: Int = 60
    var resolution: Resolution = .p1080
    var compression: Compression = .social

    var effectiveFrameRate: Int { format == .gif ? min(fps, Self.gifMaxFrameRate) : fps }

    /// Output scale for a canvas (never upscales).
    func outputScale(for canvas: CGSize) -> CGFloat {
        var shortSide = resolution.shortSide
        if format == .gif { shortSide = min(shortSide, Self.gifMaxShortSide) }
        return min(1, shortSide / max(1, min(canvas.width, canvas.height)))
    }
}
