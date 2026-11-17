import AVFoundation
import XCTest
@testable import MiRecorder

final class TimeMapTests: XCTestCase {
    // 10 s recording: cut 2–4, 4× speed 6–8, 1 s intro, 2 s outro.
    private let map = TimeMap(
        edits: [TimeEdit(start: 2, end: 4, speed: 0), TimeEdit(start: 6, end: 8, speed: 4)],
        sourceDuration: 10, intro: 1, outro: 2
    )

    func testDurations() {
        // 2 + (6-4) + 2/4 + 2 = 6.5 s of content.
        XCTAssertEqual(map.contentDuration, 6.5, accuracy: 1e-9)
        XCTAssertEqual(map.totalDuration, 9.5, accuracy: 1e-9)
    }

    func testMappingBothWays() {
        XCTAssertEqual(map.edited(atSource: 1), 2, accuracy: 1e-9, "intro shifts everything by 1 s")
        XCTAssertEqual(map.edited(atSource: 3), 3, accuracy: 1e-9, "inside the cut → where it ends")
        XCTAssertEqual(map.edited(atSource: 7), 5.25, accuracy: 1e-9, "4× section")
        XCTAssertEqual(map.source(atEdited: 5.25), 7, accuracy: 1e-9)
        XCTAssertEqual(map.source(atEdited: 0.5), 0, accuracy: 1e-9, "intro shows the first frame")
        XCTAssertTrue(map.isIntro(0.5))
        XCTAssertTrue(map.isOutro(8))
        XCTAssertEqual(map.source(atEdited: 9), 10, accuracy: 1e-9)
    }

    func testTrimRangeIncludesIntroAndOutroOnlyWhenUntrimmed() {
        let full = map.editedRange(trimStart: 0, trimEnd: 10)
        XCTAssertEqual(full.start, 0)
        XCTAssertEqual(full.end, 9.5, accuracy: 1e-9)
        let trimmed = map.editedRange(trimStart: 1, trimEnd: 9)
        XCTAssertEqual(trimmed.start, 2, accuracy: 1e-9)
        XCTAssertEqual(trimmed.end, 6.5, accuracy: 1e-9)
    }
}

final class AppliedTimelineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "mirecorder-effects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCutsSpeedIntroOutroChangeTheCompositionLength() async throws {
        let source = dir.appending(path: "s.mov")
        try await SyntheticVideo.write(to: source, size: CGSize(width: 320, height: 180), frames: 120) // 4 s
        var settings = EditSettings()
        settings.timeEdits = [TimeEdit(start: 0.5, end: 1.5, speed: 0), TimeEdit(start: 2, end: 4, speed: 2)]
        settings.intro = TitleCard(enabled: true, title: "Hola", subtitle: "", duration: 1)
        settings.outro = TitleCard(enabled: true, title: "Fin", subtitle: "", duration: 1)
        settings.clickSound = true
        let cursor = CursorTrack(samples: [CursorSample(t: 0, x: 0.5, y: 0.5)], clicks: [CursorSample(t: 0.2, x: 0.5, y: 0.5), CursorSample(t: 3, x: 0.5, y: 0.5)])

        let base = try await RecordingTimeline.load(screen: AVURLAsset(url: source))
        let applied = try await base.applying(settings, cursor: cursor, folder: dir)
        // 4 s − 1 s cut − 1 s saved by 2× + 1 s intro + 1 s outro = 4 s.
        XCTAssertEqual(applied.timeMap.totalDuration, 4, accuracy: 0.01)
        XCTAssertEqual(applied.composition.duration.seconds, 4, accuracy: 0.05)
        let audio = try await applied.composition.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1, "click sound track")
        XCTAssertNotNil(applied.audioMix)
    }

    func testExportWithEveryVisualEffect() async throws {
        let source = dir.appending(path: "fx.mov")
        try await SyntheticVideo.write(to: source, size: CGSize(width: 640, height: 360), frames: 60)
        var settings = EditSettings()
        settings.backgroundKind = .color
        settings.backgroundBlur = 0.3
        settings.windowFrame = .dark
        settings.cursorStyle = .halo
        settings.hideIdleCursor = true
        settings.annotations = [
            Annotation(start: 0, end: 2, kind: .text, text: "Hola"),
            Annotation(start: 0, end: 2, kind: .arrow),
            Annotation(start: 0, end: 2, kind: .box),
            Annotation(start: 0, end: 2, kind: .spotlight),
            Annotation(start: 0, end: 2, kind: .blur),
        ]
        settings.intro = TitleCard(enabled: true, title: "Intro", subtitle: "Sub", duration: 1)
        let keys = [KeyStroke(t: 0.5, label: "⌘C")]
        let cursor = CursorTrack(samples: [CursorSample(t: 0, x: 0.3, y: 0.3), CursorSample(t: 2, x: 0.6, y: 0.6)], clicks: [])

        let timeline = try await RecordingTimeline.load(screen: AVURLAsset(url: source)).applying(settings, cursor: cursor, folder: dir)
        let output = dir.appending(path: "fx.mp4")
        try await VideoExporter.export(
            timeline: timeline, cursor: cursor, settings: settings, sprite: nil, keystrokes: keys,
            timeRange: timeline.exportRange(for: settings), options: ExportOptions(), to: output
        )
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.1, "1 s intro + 2 s video")
    }

    func testCursorHidesAfterBeingIdle() {
        let track = CursorTrack(samples: [CursorSample(t: 0, x: 0.1, y: 0.1), CursorSample(t: 1, x: 0.5, y: 0.5), CursorSample(t: 5, x: 0.5, y: 0.5)], clicks: [])
        let activity = CursorActivity(track: track, delay: 1.5)
        XCTAssertEqual(activity.alpha(at: 2), 1)
        XCTAssertEqual(activity.alpha(at: 4), 0)
    }

    func testNoiseGateTapIsCreated() {
        XCTAssertNotNil(NoiseGate.makeTap())
    }
}

final class AudioAnalysisTests: XCTestCase {
    /// A file with a real audio track: 1 s silence, then 1 s of a 440 Hz tone.
    private func audioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mirecorder-tone-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        buffer.frameLength = 96_000
        for i in 0..<96_000 {
            buffer.floatChannelData![0][i] = i < 48_000 ? 0 : Float(sin(2 * .pi * 440 * Double(i) / 48_000) * 0.05)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testWaveformFollowsTheAudio() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let peaks = await AudioEffects.waveform(for: AVURLAsset(url: url), buckets: 100)
        XCTAssertEqual(peaks.count, 100)
        XCTAssertLessThan(peaks[10], 0.05, "silent first half")
        XCTAssertGreaterThan(peaks[80], 0.8, "tone in the second half")
    }

    func testNormalizationBoostsQuietAudio() async throws {
        let url = try audioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let gain = await AudioEffects.normalizationGain(for: AVURLAsset(url: url))
        XCTAssertGreaterThan(gain, 2, "0.05 peak tone is quiet")
    }
}
