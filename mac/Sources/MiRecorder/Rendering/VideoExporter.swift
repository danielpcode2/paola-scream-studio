import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Screen recording segments (one per pause) + their audio + optional camera clip, on one timeline.
struct RecordingTimeline: @unchecked Sendable {
    var composition: AVComposition
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let sourceSize: CGSize
    /// Length of the original recording (seconds).
    let duration: Double
    /// Original recording ↔ final video time. Identity until `applying(...)`.
    var timeMap: TimeMap
    var audioMix: AVAudioMix?
    /// Untouched recording, kept so effects can be re-applied from scratch.
    var base: AVComposition?

    enum TimelineError: LocalizedError {
        case noVideo

        var errorDescription: String? { tr("error.no_video") }
    }

    static func load(screen: AVAsset, camera: AVAsset? = nil, cameraOffset: Double = 0) async throws -> RecordingTimeline {
        try await load(screens: [screen], camera: camera, cameraOffset: cameraOffset)
    }

    static func load(screens: [AVAsset], camera: AVAsset? = nil, cameraOffset: Double = 0) async throws -> RecordingTimeline {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TimelineError.noVideo
        }
        var audioTracks: [AVMutableCompositionTrack] = []
        var sourceSize: CGSize?
        var cursor = CMTime.zero

        for screen in screens {
            let duration = try await screen.load(.duration)
            guard let screenVideo = try await screen.loadTracks(withMediaType: .video).first else { continue }
            let whole = CMTimeRange(start: .zero, duration: duration)
            let range = try await screenVideo.load(.timeRange).intersection(whole)
            guard !range.isEmpty else { continue }
            try videoTrack.insertTimeRange(range, of: screenVideo, at: cursor + range.start)
            if sourceSize == nil { sourceSize = try await screenVideo.load(.naturalSize) }

            // System audio and microphone arrive as separate tracks; keep each on its own composition track.
            for (index, audio) in try await screen.loadTracks(withMediaType: .audio).enumerated() {
                let audioRange = try await audio.load(.timeRange).intersection(whole)
                guard !audioRange.isEmpty else { continue }
                if index >= audioTracks.count,
                   let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    audioTracks.append(track)
                }
                guard index < audioTracks.count else { continue }
                try audioTracks[index].insertTimeRange(audioRange, of: audio, at: cursor + audioRange.start)
            }
            cursor = cursor + duration
        }
        guard let sourceSize, cursor > .zero else { throw TimelineError.noVideo }

        var cameraTrackID: CMPersistentTrackID?
        if let camera, let cameraVideo = try await camera.loadTracks(withMediaType: .video).first {
            let source = try await cameraVideo.load(.timeRange)
            var sourceStart = source.start
            var destination = source.start + CMTime(seconds: cameraOffset, preferredTimescale: 600)
            if destination < .zero { // camera started before the screen: drop the early part
                sourceStart = sourceStart - destination
                destination = .zero
            }
            let length = CMTimeMinimum(source.end - sourceStart, cursor - destination)
            if length > .zero,
               let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(CMTimeRange(start: sourceStart, duration: length), of: cameraVideo, at: destination)
                cameraTrackID = track.trackID
            }
        }

        return RecordingTimeline(
            composition: composition,
            screenTrackID: videoTrack.trackID,
            cameraTrackID: cameraTrackID,
            sourceSize: sourceSize,
            duration: cursor.seconds,
            timeMap: .identity(duration: cursor.seconds),
            audioMix: nil,
            base: composition.copy() as? AVComposition
        )
    }

    /// Applies timing and audio effects: click sounds, cuts and speed changes, intro/outro and
    /// background music (from `folder`), plus the audio mix.
    func applying(_ settings: EditSettings, cursor: CursorTrack, folder: URL?) async throws -> RecordingTimeline {
        guard let base, let composition = base.mutableCopy() as? AVMutableComposition else { return self }
        let recordingAudio = try await composition.loadTracks(withMediaType: .audio)
        let normalizationGain = settings.normalizeAudio ? await AudioEffects.normalizationGain(for: base) : 1

        // 1. Click sounds, placed in recording time so later edits move them with the video.
        var clickTrack: AVMutableCompositionTrack?
        if settings.clickSound, !cursor.clicks.isEmpty,
           let sound = try? await AVURLAsset(url: AudioEffects.clickSoundURL()).loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let soundRange = try await sound.load(.timeRange)
            var nextFree = 0.0
            for click in cursor.clicks.sorted(by: { $0.t < $1.t }) where click.t >= nextFree && click.t < duration {
                try? track.insertTimeRange(soundRange, of: sound, at: CMTime(seconds: click.t, preferredTimescale: 600))
                nextFree = click.t + soundRange.duration.seconds + 0.01
            }
            clickTrack = track
        }

        // 2. Cuts and speed changes, from the end so earlier times stay valid.
        let edits = SpanEditing.normalized(settings.timeEdits, duration: duration)
        for edit in edits.reversed() {
            let range = CMTimeRange(
                start: CMTime(seconds: edit.start, preferredTimescale: 600),
                end: CMTime(seconds: edit.end, preferredTimescale: 600)
            )
            if edit.isCut {
                composition.removeTimeRange(range)
            } else {
                composition.scaleTimeRange(range, toDuration: CMTime(seconds: (edit.end - edit.start) / edit.speed, preferredTimescale: 600))
            }
        }

        // 3. Intro and outro: empty time where title cards are drawn.
        let intro = settings.intro.enabled ? settings.intro.duration : 0
        let outro = settings.outro.enabled ? settings.outro.duration : 0
        if intro > 0 {
            composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: intro, preferredTimescale: 600)))
        }
        // Empty time at the very end does not extend a composition, so the outro holds the last
        // screen frame (the renderer draws the outro card over it).
        if outro > 0, let screen = composition.track(withTrackID: screenTrackID), let baseScreen = base.track(withTrackID: screenTrackID) {
            let end = composition.duration
            let frame = CMTime(value: 1, timescale: 30)
            let last = CMTimeRange(start: baseScreen.timeRange.end - frame, duration: frame)
            try screen.insertTimeRange(last, of: baseScreen, at: end)
            screen.scaleTimeRange(CMTimeRange(start: end, duration: frame), toDuration: CMTime(seconds: outro, preferredTimescale: 600))
        }
        let total = composition.duration

        // 4. Background music, looped over the whole final video (not affected by edits).
        var musicTrack: AVMutableCompositionTrack?
        if let file = settings.musicFile, let folder,
           let music = try? await AVURLAsset(url: folder.appending(path: file)).loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let musicRange = try await music.load(.timeRange)
            var position = CMTime.zero
            let musicLength = musicRange.duration.seconds
            while musicLength > 0, position.seconds < total.seconds - 0.001 {
                let length = CMTimeMinimum(musicRange.duration, total - position)
                try track.insertTimeRange(CMTimeRange(start: musicRange.start, duration: length), of: music, at: position)
                position = position + length
            }
            musicTrack = track
        }

        let recordingTracks = recordingAudio.compactMap { composition.track(withTrackID: $0.trackID) }
        var result = self
        result.composition = composition
        result.timeMap = TimeMap(edits: edits, sourceDuration: duration, intro: intro, outro: outro)
        result.audioMix = AudioEffects.makeMix(
            recordingTracks: recordingTracks,
            clickTrack: clickTrack,
            musicTrack: musicTrack,
            settings: settings,
            normalizationGain: normalizationGain,
            totalDuration: total
        )
        return result
    }

    /// Final-video range for the project's trim.
    func exportRange(for settings: EditSettings) -> CMTimeRange {
        let range = timeMap.editedRange(trimStart: settings.trimStart, trimEnd: min(settings.trimEnd ?? duration, duration))
        return CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: 600),
            end: CMTime(seconds: range.end, preferredTimescale: 600)
        )
    }
}

enum CompositionBuilder {
    /// Same pipeline for preview (downscaled) and export.
    static func make(
        timeline: RecordingTimeline,
        cursor: CursorTrack,
        settings: EditSettings,
        sprite: CursorSprite?,
        keystrokes: [KeyStroke] = [],
        outputScale: CGFloat = 1,
        fps: Int = 60
    ) -> AVMutableVideoComposition {
        let renderer = FrameCompositor(
            sourceSize: timeline.sourceSize,
            cursor: cursor,
            settings: settings,
            sprite: sprite,
            keystrokes: keystrokes,
            timeMap: timeline.timeMap,
            outputScale: outputScale
        )
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = StudioVideoCompositor.self
        composition.renderSize = renderer.outputSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps, 1)))
        composition.instructions = [
            StudioInstruction(
                timeRange: CMTimeRange(start: .zero, duration: timeline.composition.duration),
                screenTrackID: timeline.screenTrackID,
                cameraTrackID: timeline.cameraTrackID,
                renderer: renderer
            ),
        ]
        return composition
    }

    /// Scale that keeps the preview's longest side at or under `maxDimension`.
    static func previewScale(sourceSize: CGSize, settings: EditSettings, maxDimension: CGFloat = 1920) -> CGFloat {
        let canvas = settings.aspect.canvasSize(for: sourceSize)
        return min(1, maxDimension / max(canvas.width, canvas.height, 1))
    }
}

final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let renderer: FrameCompositor

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?, renderer: FrameCompositor) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.renderer = renderer
        self.requiredSourceTrackIDs = ([screenTrackID] + (cameraTrackID.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// Custom compositor: feeds screen + camera frames to `FrameCompositor` and renders with Core Image.
final class StudioVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
    ]
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? StudioInstruction,
              let output = request.renderContext.newPixelBuffer()
        else {
            request.finish(with: NSError(domain: "MiRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Render context unavailable"]))
            return
        }
        // No screen frame during intro/outro (empty time): the renderer draws the title cards.
        let screen = request.sourceFrame(byTrackID: instruction.screenTrackID).map { CIImage(cvPixelBuffer: $0) }
        let cameraBuffer = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }
        let cameraMask = instruction.renderer.needsPersonMask ? cameraBuffer.flatMap(Self.personMask) : nil
        let image = instruction.renderer.render(
            source: screen,
            camera: cameraBuffer.map { CIImage(cvPixelBuffer: $0) },
            cameraMask: cameraMask,
            at: request.compositionTime.seconds
        )
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: request.renderContext.size), colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    /// Person segmentation of a camera frame (white = person), for blurring the camera background.
    private static func personMask(_ buffer: CVPixelBuffer) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        guard let mask = request.results?.first?.pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: mask)
        let sx = CGFloat(CVPixelBufferGetWidth(buffer)) / image.extent.width
        let sy = CGFloat(CVPixelBufferGetHeight(buffer)) / image.extent.height
        return image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }
}

/// Renders the edited project to MP4 (H.264/HEVC), ProRes .mov or animated GIF.
enum VideoExporter {
    enum ExportError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let reason): reason
            }
        }
    }

    static func export(
        timeline: RecordingTimeline,
        cursor: CursorTrack,
        settings: EditSettings,
        sprite: CursorSprite?,
        keystrokes: [KeyStroke] = [],
        timeRange: CMTimeRange,
        options: ExportOptions = ExportOptions(),
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let canvas = settings.aspect.canvasSize(for: timeline.sourceSize)
        let fps = options.effectiveFrameRate
        let videoComposition = CompositionBuilder.make(
            timeline: timeline,
            cursor: cursor,
            settings: settings,
            sprite: sprite,
            keystrokes: keystrokes,
            outputScale: options.outputScale(for: canvas),
            fps: fps
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let reader = try AVAssetReader(asset: timeline.composition)
        reader.timeRange = timeRange
        let videoTracks = try await timeline.composition.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let report: @Sendable (CMTime) -> Void = { time in
            let done = (time - timeRange.start).seconds / max(timeRange.duration.seconds, 0.001)
            progress(min(max(done, 0), 1))
        }

        if options.format == .gif {
            try writeGIF(reader: reader, output: videoOutput, fps: fps, duration: timeRange.duration.seconds, to: url, report: report)
        } else {
            let audioTracks = try await timeline.composition.loadTracks(withMediaType: .audio)
            try await writeMovie(
                reader: reader, videoOutput: videoOutput, audioTracks: audioTracks, audioMix: timeline.audioMix,
                renderSize: videoComposition.renderSize, fps: fps, options: options,
                startTime: timeRange.start, to: url, report: report
            )
        }
        progress(1)
    }

    private static func writeMovie(
        reader: AVAssetReader,
        videoOutput: AVAssetReaderOutput,
        audioTracks: [AVAssetTrack],
        audioMix: AVAudioMix?,
        renderSize: CGSize,
        fps: Int,
        options: ExportOptions,
        startTime: CMTime,
        to url: URL,
        report: @escaping @Sendable (CMTime) -> Void
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: options.format == .prores ? .mov : .mp4)
        let width = Int(renderSize.width), height = Int(renderSize.height)
        var videoSettings: [String: Any] = [AVVideoWidthKey: width, AVVideoHeightKey: height]
        if options.format == .prores {
            videoSettings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        } else {
            // H.264 tops out around 4096 px / ~8.9 MP per frame; use HEVC beyond that.
            let needsHEVC = max(width, height) > 4096 || width * height > 8_912_896
            let bitrate = options.compression.bitsPerPixel * Double(width * height * fps)
            videoSettings[AVVideoCodecKey] = needsHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ]
            if !needsHEVC { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)?
        if !audioTracks.isEmpty {
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            audioOutput.audioMix = audioMix
            audioOutput.audioTimePitchAlgorithm = .spectral // sped-up parts keep a natural pitch
            reader.add(audioOutput)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            audioInput.expectsMediaDataInRealTime = false
            writer.add(audioInput)
            audioPair = (audioOutput, audioInput)
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.failed("reader") }
        guard writer.startWriting() else { throw writer.error ?? ExportError.failed("writer") }
        writer.startSession(atSourceTime: startTime)

        async let video: Void = pump(videoOutput, into: videoInput, label: "video", onSample: report)
        if let audioPair {
            await pump(audioPair.0, into: audioPair.1, label: "audio", onSample: nil)
        }
        await video

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? ExportError.failed("reader")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ExportError.failed("writer")
        }
    }

    private static func pump(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        label: String,
        onSample: (@Sendable (CMTime) -> Void)?
    ) async {
        let queue = DispatchQueue(label: "mirecorder.export.\(label)")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        break
                    }
                    guard input.append(sample) else {
                        finished = true
                        break
                    }
                    onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
                }
                if finished {
                    input.markAsFinished()
                    continuation.resume()
                }
            }
        }
    }

    private static func writeGIF(
        reader: AVAssetReader,
        output: AVAssetReaderOutput,
        fps: Int,
        duration: Double,
        to url: URL,
        report: @Sendable (CMTime) -> Void
    ) throws {
        // ImageIO needs the frame count up front; the composition yields one frame per 1/fps.
        let frameCount = max(1, Int((duration * Double(fps)).rounded()))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ExportError.failed("gif")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0],
        ] as CFDictionary)
        let delay = 1.0 / Double(fps)
        let frameProperties = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: delay,
                kCGImagePropertyGIFUnclampedDelayTime as String: delay,
            ],
        ] as CFDictionary

        guard reader.startReading() else { throw reader.error ?? ExportError.failed("reader") }
        let context = CIContext()
        var written = 0
        var last: CGImage?
        while written < frameCount, let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let image = CIImage(cvPixelBuffer: buffer)
            guard let frame = context.createCGImage(image, from: image.extent) else { continue }
            CGImageDestinationAddImage(destination, frame, frameProperties)
            last = frame
            written += 1
            report(CMSampleBufferGetPresentationTimeStamp(sample))
        }
        reader.cancelReading()
        guard let last else { throw ExportError.failed("gif: no frames") }
        while written < frameCount { // pad if the reader produced slightly fewer frames
            CGImageDestinationAddImage(destination, last, frameProperties)
            written += 1
        }
        guard CGImageDestinationFinalize(destination) else { throw ExportError.failed("gif") }
    }
}
