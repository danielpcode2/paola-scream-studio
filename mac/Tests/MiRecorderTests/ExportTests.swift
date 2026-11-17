import AVFoundation
import XCTest
@testable import MiRecorder

final class ExportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "mirecorder-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testExportProducesCanvasSizedVideoForTrimmedRange() async throws {
        let source = dir.appending(path: "source.mov")
        let size = CGSize(width: 640, height: 360)
        try await writeSyntheticVideo(to: source, size: size, frames: 60, gray: { UInt8(($0 * 4) % 255) })

        var settings = EditSettings()
        settings.aspect = .square
        settings.zoomSegments = [ZoomSegment(start: 0.2, end: 1.5, scale: 2)]
        let cursor = CursorTrack(
            samples: [CursorSample(t: 0, x: 0.2, y: 0.2), CursorSample(t: 2, x: 0.8, y: 0.7)],
            clicks: [CursorSample(t: 0.5, x: 0.5, y: 0.5)]
        )
        let sprite = await MainActor.run { CursorSprite.systemArrow() }
        let timeline = try await RecordingTimeline.load(screen: AVURLAsset(url: source))
        XCTAssertNil(timeline.cameraTrackID)

        let output = dir.appending(path: "out.mp4")
        try await VideoExporter.export(
            timeline: timeline,
            cursor: cursor,
            settings: settings,
            sprite: sprite,
            timeRange: CMTimeRange(start: .zero, end: CMTime(seconds: 1.5, preferredTimescale: 600)),
            to: output
        )

        let exported = AVURLAsset(url: output)
        let tracks = try await exported.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 360, height: 360))
        let duration = try await exported.load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.1)
    }

    func testCameraAppearsInsideBubbleOnlyAndFollowsOffset() async throws {
        let size = CGSize(width: 640, height: 360)
        let screen = dir.appending(path: "screen.mov")
        let camera = dir.appending(path: "camera.mov")
        try await writeSyntheticVideo(to: screen, size: size, frames: 60, gray: { _ in 30 })
        try await writeSyntheticVideo(to: camera, size: CGSize(width: 320, height: 240), frames: 60, gray: { _ in 230 })

        // Camera started 0.5 s after the screen.
        let timeline = try await RecordingTimeline.load(
            screen: AVURLAsset(url: screen),
            camera: AVURLAsset(url: camera),
            cameraOffset: 0.5
        )
        XCTAssertNotNil(timeline.cameraTrackID)

        var settings = EditSettings()
        settings.padding = 0
        settings.shadow = 0
        settings.showCursor = false
        settings.cameraSize = 0.4
        let output = dir.appending(path: "camera-out.mp4")
        try await VideoExporter.export(
            timeline: timeline,
            cursor: CursorTrack(),
            settings: settings,
            sprite: nil,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)),
            to: output
        )

        let geometry = FrameCompositor(sourceSize: size, cursor: CursorTrack(), settings: settings, sprite: nil)
        let bubble = geometry.cameraCenter
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let later = try await generator.image(at: CMTime(seconds: 1.2, preferredTimescale: 600)).image
        XCTAssertGreaterThan(luma(later, at: bubble), 180, "camera visible inside bubble")
        XCTAssertLessThan(luma(later, at: CGPoint(x: 120, y: 250)), 80, "screen visible outside bubble")

        let before = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        XCTAssertLessThan(luma(before, at: bubble), 80, "no camera before its offset")
    }

    // MARK: - Helpers

    /// Average of RGB at a point given in CoreImage coordinates (origin bottom-left).
    private func luma(_ image: CGImage, at point: CGPoint) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Shift the image so the requested pixel lands on the 1×1 context.
        context.draw(image, in: CGRect(x: -point.x, y: -point.y, width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3
    }

    private func writeSyntheticVideo(to url: URL, size: CGSize, frames: Int, gray: (Int) -> UInt8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(gray(frame)), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}

final class ModelTests: XCTestCase {
    func testRegionRectIsNormalizedAndClamped() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let rect = RegionMath.rect(from: CGPoint(x: 900, y: 700), to: CGPoint(x: 1200, y: 100), in: bounds)
        XCTAssertEqual(rect, CGRect(x: 900, y: 100, width: 100, height: 600))
        XCTAssertTrue(RegionMath.isUsable(rect))
        XCTAssertFalse(RegionMath.isUsable(CGRect(x: 0, y: 0, width: 30, height: 300)))
    }

    func testSettingsSavedBeforeCameraSupportStillDecode() throws {
        let legacy = #"{"padding":0.1,"aspect":"square","zoomSegments":[]}"#
        let settings = try JSONDecoder().decode(EditSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.padding, 0.1)
        XCTAssertEqual(settings.aspect, .square)
        XCTAssertEqual(settings.cameraCorner, .bottomRight)
        XCTAssertTrue(settings.showCamera)
    }
}
