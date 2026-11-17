import AVFoundation
import ImageIO
import XCTest
@testable import PaolaScreenStudio

final class RecordingClockTests: XCTestCase {
    func testPausedTimeIsRemovedFromProjectTimeline() {
        // Segment 1: uptime 100–105, paused 105–110, segment 2: 110–113.
        let clock = RecordingClock(segments: [.init(startUptime: 100, duration: 5), .init(startUptime: 110, duration: 3)])
        XCTAssertEqual(clock.totalDuration, 8)
        XCTAssertEqual(clock.projectTime(99), 0, "pre-roll maps to the start")
        XCTAssertEqual(clock.projectTime(102), 2)
        XCTAssertNil(clock.projectTime(107), "paused")
        XCTAssertEqual(try XCTUnwrap(clock.projectTime(111.5)), 6.5, accuracy: 1e-9)
        XCTAssertNil(clock.projectTime(120), "after the end")
    }
}

final class TimelineAndExportFormatTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "mirecorder-feature-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSegmentsAreConcatenated() async throws {
        let a = dir.appending(path: "a.mov"), b = dir.appending(path: "b.mov")
        try await SyntheticVideo.write(to: a, size: CGSize(width: 320, height: 180), frames: 30)
        try await SyntheticVideo.write(to: b, size: CGSize(width: 320, height: 180), frames: 45)
        let timeline = try await RecordingTimeline.load(screens: [AVURLAsset(url: a), AVURLAsset(url: b)])
        XCTAssertEqual(timeline.duration, 2.5, accuracy: 0.05)
        XCTAssertEqual(timeline.sourceSize, CGSize(width: 320, height: 180))
    }

    func testExportDownscalesToRequestedResolution() async throws {
        let source = dir.appending(path: "big.mov")
        try await SyntheticVideo.write(to: source, size: CGSize(width: 1920, height: 1080), frames: 15)
        let timeline = try await RecordingTimeline.load(screen: AVURLAsset(url: source))
        var options = ExportOptions()
        options.resolution = .p720
        options.fps = 30
        options.compression = .web
        let output = dir.appending(path: "small.mp4")
        try await VideoExporter.export(
            timeline: timeline, cursor: CursorTrack(), settings: EditSettings(), sprite: nil,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 600)),
            options: options, to: output
        )
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
    }

    func testGIFExportHasOneFramePerFrameInterval() async throws {
        let source = dir.appending(path: "gif-source.mov")
        try await SyntheticVideo.write(to: source, size: CGSize(width: 320, height: 180), frames: 30)
        let timeline = try await RecordingTimeline.load(screen: AVURLAsset(url: source))
        var options = ExportOptions()
        options.format = .gif
        options.fps = 60 // capped to 30 for GIF
        let output = dir.appending(path: "out.gif")
        try await VideoExporter.export(
            timeline: timeline, cursor: CursorTrack(), settings: EditSettings(), sprite: nil,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 600)),
            options: options, to: output
        )
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 15)
    }

    func testProResExportWritesMovie() async throws {
        let source = dir.appending(path: "prores-source.mov")
        try await SyntheticVideo.write(to: source, size: CGSize(width: 320, height: 180), frames: 10)
        let timeline = try await RecordingTimeline.load(screen: AVURLAsset(url: source))
        var options = ExportOptions()
        options.format = .prores
        let output = dir.appending(path: "out.mov")
        try await VideoExporter.export(
            timeline: timeline, cursor: CursorTrack(), settings: EditSettings(), sprite: nil,
            timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 0.3, preferredTimescale: 600)),
            options: options, to: output
        )
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let format = try await XCTUnwrap(tracks.first).load(.formatDescriptions).first
        XCTAssertEqual(format.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_AppleProRes422)
    }
}

final class LocalizationAndShortcutTests: XCTestCase {
    func testEveryUsedKeyIsTranslatedInBothLanguages() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/PaolaScreenStudio")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let regex = try NSRegularExpression(pattern: #"tr\("([a-zA-Z0-9_.]+)""#)
        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        // Keys built from enum raw values.
        keys.formUnion(ShortcutAction.allCases.map { "shortcut.\($0.rawValue)" })
        keys.formUnion(SettingsTab.allCases.map { "settings.tab.\($0.rawValue)" })
        keys.formUnion(ExportOptions.Compression.allCases.flatMap { ["compression.\($0.rawValue)", "compression.\($0.rawValue).detail"] })
        keys.formUnion(AnnotationKind.allCases.flatMap { ["annotation.kind.\($0.rawValue)", "annotation.position_hint.\($0.rawValue)"] })
        keys.formUnion(BackgroundKind.allCases.map { "background.\($0.rawValue)" })
        keys.formUnion(CameraLayout.allCases.map { "camera.layout.\($0.rawValue)" })
        keys.formUnion(CursorStyle.allCases.map { "cursor.style.\($0.rawValue)" })
        keys.formUnion(WindowFrameStyle.allCases.map { "frame.\($0.rawValue)" })
        keys.formUnion(InspectorTab.allCases.map { "inspector.tab.\($0.rawValue)" })
        keys.formUnion(EditorModel.PreviewQuality.allCases.map { "preview.quality.\($0.rawValue)" })

        XCTAssertGreaterThan(keys.count, 100)
        let missing = keys.filter { Strings.table[$0] == nil }.sorted()
        XCTAssertEqual(missing, [], "untranslated keys")
        let empty = Strings.table.filter { $0.value.es.isEmpty || $0.value.en.isEmpty }.map(\.key)
        XCTAssertEqual(empty, [])
    }

    func testDefaultShortcutsAreDistinctAndDisplayLikeMacMenus() throws {
        let combos = ShortcutAction.defaults.values.compactMap { $0 }
        XCTAssertEqual(combos.count, ShortcutAction.allCases.count)
        XCTAssertEqual(Set(combos).count, combos.count, "no duplicates")
        XCTAssertEqual(ShortcutAction.defaults[.recordArea]??.display, "⌥⌘5")
        XCTAssertEqual(ShortcutAction.defaults[.newRecording]??.display, "⌃⌘↩")
        XCTAssertEqual(ShortcutAction.defaults[.flag]??.display, "⌃⌥⌘F")
    }

    func testStyleOnlyDropsRecordingSpecificEdits() {
        var settings = EditSettings()
        settings.padding = 0.15
        settings.zoomSegments = [ZoomSegment(start: 1, end: 2, scale: 2)]
        settings.trimStart = 3
        settings.trimEnd = 9
        let style = settings.styleOnly
        XCTAssertEqual(style.padding, 0.15)
        XCTAssertTrue(style.zoomSegments.isEmpty)
        XCTAssertEqual(style.trimStart, 0)
        XCTAssertNil(style.trimEnd)

        var preset = EditSettings()
        preset.padding = 0.01
        let applied = settings.applyingStyle(preset)
        XCTAssertEqual(applied.padding, 0.01)
        XCTAssertEqual(applied.zoomSegments.count, 1, "keeps the project's zooms")
        XCTAssertEqual(applied.trimEnd, 9)
    }
}

enum SyntheticVideo {
    static func write(to url: URL, size: CGSize, frames: Int, gray: UInt8 = 90) async throws {
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
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(gray), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

final class CameraShapeTests: XCTestCase {
    func testOldProjectsDefaultToCircle() throws {
        let decoded = try JSONDecoder().decode(EditSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.cameraShape, .circle)
        XCTAssertEqual(decoded.cameraBorderColor, RGBAColor(1, 1, 1, 0.95))
    }

    func testBorderColorRoundTrips() throws {
        var settings = EditSettings()
        settings.cameraBorderColor = RGBAColor(0.55, 0.36, 0.96)
        let decoded = try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.cameraBorderColor, settings.cameraBorderColor)
    }

    func testShapeRoundTrips() throws {
        var settings = EditSettings()
        settings.cameraShape = .rounded
        let decoded = try JSONDecoder().decode(EditSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.cameraShape, .rounded)
    }
}
