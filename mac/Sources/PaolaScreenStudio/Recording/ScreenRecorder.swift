import AVFoundation
import AppKit
import ScreenCaptureKit

enum CaptureTarget: Equatable, Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// Area in display points, origin top-left of that display.
    case area(display: CGDirectDisplayID, rect: CGRect)
    /// iPhone / iPad connected by USB.
    case device(String)
}

/// What a finished recording produced; the coordinator turns it into a project.
struct CapturedRecording: Sendable {
    let folder: URL
    let segmentFiles: [String]
    let cursor: CursorTrack
    let flags: [Double]
    let keystrokes: [KeyStroke]
    let camera: CameraClip?
    let duration: Double
}

/// Records a display, window or area with ScreenCaptureKit (video + system audio + microphone),
/// one .mov segment per pause/resume, plus an optional camera clip.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, starting, recording, paused, stopping
    }

    struct Options {
        var systemAudio: Bool
        var microphoneID: String?
        var cameraEnabled: Bool
        /// Our own windows that must still be captured (desktop cover).
        var includedWindowIDs: [CGWindowID] = []
        var recordKeystrokes = false
    }

    enum RecorderError: LocalizedError {
        case noDisplay, noWindow, noArea

        var errorDescription: String? {
            switch self {
            case .noDisplay: tr("error.no_display")
            case .noWindow: tr("error.no_window")
            case .noArea: tr("error.no_area")
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published var errorMessage: String?

    let camera = CameraRecorder()
    /// Called when the stream stops on its own (e.g. display disconnected) with whatever was saved.
    var onUnexpectedStop: ((CapturedRecording?) -> Void)?

    private final class Segment {
        let output: SCRecordingOutput
        let fileName: String
        var startUptime: TimeInterval?
        var result: Result<Void, Error>?
        var waiter: CheckedContinuation<Void, Error>?

        init(output: SCRecordingOutput, fileName: String) {
            self.output = output
            self.fileName = fileName
        }
    }

    private let tracker = CursorTracker()
    private var stream: SCStream?
    private var folder: URL?
    private var captureFrame: CGRect = .zero
    private var segments: [Segment] = []
    private var flagUptimes: [TimeInterval] = []
    private var device: DeviceCapture?
    private var deviceFlags: [Double] = []
    private var activeSince: Date?
    private var accumulated: TimeInterval = 0

    var isActive: Bool { state == .recording || state == .paused }

    /// Recorded time, excluding pauses.
    var elapsed: TimeInterval { accumulated + (activeSince.map { Date().timeIntervalSince($0) } ?? 0) }

    func start(target: CaptureTarget, options: Options) async {
        guard state == .idle else { return }
        state = .starting
        errorMessage = nil
        if case .device(let id) = target {
            await startDevice(id, options: options)
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let filter: SCContentFilter
            var sourceRect: CGRect?
            let capturedSize: CGSize

            switch target {
            case .display(let id), .area(let id, _):
                guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecorderError.noDisplay }
                // Never record our own windows (toolbar, camera bubble, overlays) except the desktop cover.
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let included = content.windows.filter { options.includedWindowIDs.contains($0.windowID) }
                filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: included)
                if case .area(_, let rect) = target {
                    let area = rect.intersection(CGRect(x: 0, y: 0, width: display.width, height: display.height))
                    guard RegionMath.isUsable(area) else { throw RecorderError.noArea }
                    sourceRect = area
                }
                captureFrame = sourceRect.map { $0.offsetBy(dx: display.frame.minX, dy: display.frame.minY) } ?? display.frame
                capturedSize = sourceRect?.size ?? display.frame.size
            case .device:
                throw RecorderError.noDisplay // handled by startDevice
            case .window(let id):
                guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.noWindow }
                filter = SCContentFilter(desktopIndependentWindow: window)
                captureFrame = window.frame
                capturedSize = window.frame.size
            }

            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            if let sourceRect { config.sourceRect = sourceRect }
            config.width = Int(CanvasAspect.even(capturedSize.width * scale))
            config.height = Int(CanvasAspect.even(capturedSize.height * scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.showsCursor = false // drawn later, smoothed and scaled
            config.ignoreShadowsSingleWindow = true
            config.capturesAudio = options.systemAudio
            config.captureMicrophone = options.microphoneID != nil
            if let mic = options.microphoneID { config.microphoneCaptureDeviceID = mic }
            config.queueDepth = 6

            let folder = try ProjectStore.makeFolder()
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            self.folder = folder
            self.stream = stream
            segments = []
            flagUptimes = []
            try addSegment(to: stream, folder: folder)

            tracker.start(keystrokes: options.recordKeystrokes)
            try await stream.startCapture()
            if options.cameraEnabled {
                camera.startRecording(to: folder.appending(path: ProjectStore.cameraFileName))
            }
            accumulated = 0
            activeSince = Date()
            state = .recording
        } catch {
            tracker.stop()
            _ = await camera.stopRecording()
            if let folder { try? FileManager.default.removeItem(at: folder) }
            reset()
            errorMessage = Self.describe(error)
        }
    }

    /// iPhone / iPad: one movie file; pauses are left out of it by the movie output itself.
    private func startDevice(_ id: String, options: Options) async {
        do {
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw DeviceCapture.DeviceError.unavailable }
            let folder = try ProjectStore.makeFolder()
            let capture = DeviceCapture()
            self.folder = folder
            device = capture
            deviceFlags = []
            try await capture.start(deviceID: id, microphoneID: options.microphoneID, to: ProjectStore.videoURL(in: folder))
            if options.cameraEnabled {
                camera.startRecording(to: folder.appending(path: ProjectStore.cameraFileName))
            }
            accumulated = 0
            activeSince = Date()
            state = .recording
        } catch {
            await device?.stop()
            if let folder { try? FileManager.default.removeItem(at: folder) }
            device = nil
            reset()
            errorMessage = Self.describe(error)
        }
    }

    private func finishDevice(_ capture: DeviceCapture) async -> CapturedRecording? {
        await capture.stop()
        let cameraResult = await camera.stopRecording()
        defer { device = nil; reset() }
        guard let folder else { return nil }
        let duration = (try? await AVURLAsset(url: ProjectStore.videoURL(in: folder)).load(.duration).seconds) ?? 0
        guard duration > 0 else {
            try? FileManager.default.removeItem(at: folder)
            errorMessage = tr("error.nothing_recorded")
            return nil
        }
        return CapturedRecording(
            folder: folder,
            segmentFiles: [ProjectStore.segmentFileName(0)],
            cursor: CursorTrack(),
            flags: deviceFlags,
            keystrokes: [],
            camera: cameraResult.map { result in
                CameraClip(fileName: ProjectStore.cameraFileName, offset: result.startUptime - (capture.startUptime ?? result.startUptime))
            },
            duration: duration
        )
    }

    func pause() async {
        if let device, state == .recording {
            device.pause()
            camera.pause()
            if let activeSince { accumulated += Date().timeIntervalSince(activeSince) }
            activeSince = nil
            state = .paused
            return
        }
        guard state == .recording, let stream, let segment = segments.last else { return }
        state = .paused
        camera.pause()
        if let activeSince { accumulated += Date().timeIntervalSince(activeSince) }
        activeSince = nil
        do {
            try stream.removeRecordingOutput(segment.output)
            try await wait(for: segment)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func resume() async {
        if let device, state == .paused {
            device.resume()
            camera.resume()
            activeSince = Date()
            state = .recording
            return
        }
        guard state == .paused, let stream, let folder else { return }
        do {
            try addSegment(to: stream, folder: folder)
            camera.resume()
            activeSince = Date()
            state = .recording
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func addFlag() {
        guard state == .recording else { return }
        if device != nil {
            deviceFlags.append(elapsed)
            return
        }
        flagUptimes.append(ProcessInfo.processInfo.systemUptime)
    }

    /// Stops and returns the recording, ready to become a project.
    func stop() async -> CapturedRecording? {
        if isActive, let device {
            state = .stopping
            return await finishDevice(device)
        }
        guard isActive, let stream else { return nil }
        let wasRecording = state == .recording
        state = .stopping
        do {
            try await stream.stopCapture()
        } catch {
            errorMessage = Self.describe(error)
        }
        return await finish(waitForLastSegment: wasRecording)
    }

    /// Stops and deletes everything recorded.
    func cancel() async {
        if isActive, let device {
            state = .stopping
            await device.stop()
            _ = await camera.stopRecording()
            if let folder { try? FileManager.default.removeItem(at: folder) }
            self.device = nil
            reset()
            return
        }
        guard isActive, let stream else { return }
        state = .stopping
        tracker.stop()
        try? await stream.stopCapture()
        if let segment = segments.last { try? await wait(for: segment) }
        _ = await camera.stopRecording()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        reset()
    }

    private func finish(waitForLastSegment: Bool) async -> CapturedRecording? {
        tracker.stop()
        guard let folder else {
            reset()
            return nil
        }
        if waitForLastSegment, let segment = segments.last {
            do { try await wait(for: segment) } catch { errorMessage = Self.describe(error) }
        }
        let cameraResult = await camera.stopRecording()

        var clockSegments: [RecordingClock.Segment] = []
        var files: [String] = []
        for segment in segments {
            let url = folder.appending(path: segment.fileName)
            guard let start = segment.startUptime,
                  let duration = try? await AVURLAsset(url: url).load(.duration).seconds,
                  duration > 0
            else { continue }
            clockSegments.append(.init(startUptime: start, duration: duration))
            files.append(segment.fileName)
        }
        let clock = RecordingClock(segments: clockSegments)
        let captured: CapturedRecording? = files.isEmpty ? nil : CapturedRecording(
            folder: folder,
            segmentFiles: files,
            cursor: tracker.track(clock: clock, frame: captureFrame),
            flags: flagUptimes.compactMap(clock.projectTime),
            keystrokes: tracker.keystrokes(clock: clock),
            camera: cameraResult.map { result in
                CameraClip(fileName: ProjectStore.cameraFileName, offset: result.startUptime - (clockSegments.first?.startUptime ?? result.startUptime))
            },
            duration: clock.totalDuration
        )
        if captured == nil {
            try? FileManager.default.removeItem(at: folder)
            if errorMessage == nil { errorMessage = tr("error.nothing_recorded") }
        }
        reset()
        return captured
    }

    private func addSegment(to stream: SCStream, folder: URL) throws {
        let fileName = ProjectStore.segmentFileName(segments.count)
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = folder.appending(path: fileName)
        configuration.outputFileType = .mov
        configuration.videoCodecType = .hevc
        let output = SCRecordingOutput(configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)
        segments.append(Segment(output: output, fileName: fileName))
    }

    private func wait(for segment: Segment) async throws {
        if let result = segment.result { return try result.get() }
        try await withCheckedThrowingContinuation { segment.waiter = $0 }
    }

    private func segment(for output: SCRecordingOutput) -> Segment? {
        segments.first { $0.output === output }
    }

    private func complete(_ output: SCRecordingOutput, _ result: Result<Void, Error>) {
        guard let segment = segment(for: output), segment.result == nil else { return }
        segment.result = result
        segment.waiter?.resume(with: result)
        segment.waiter = nil
    }

    private func reset() {
        stream = nil
        folder = nil
        segments = []
        activeSince = nil
        state = .idle
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.userDeclined.rawValue {
            return tr("error.screen_permission")
        }
        return error.localizedDescription
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate, SCStreamDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let now = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in self.segment(for: recordingOutput)?.startUptime = now }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.complete(recordingOutput, .failure(error)) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.complete(recordingOutput, .success(())) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream, self.isActive else { return }
            self.errorMessage = Self.describe(error)
            let wasRecording = self.state == .recording
            self.state = .stopping
            let captured = await self.finish(waitForLastSegment: wasRecording)
            self.onUnexpectedStop?(captured)
        }
    }
}
