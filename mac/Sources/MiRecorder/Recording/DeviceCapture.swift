import AVFoundation
import CoreMediaIO

/// iPhone / iPad screens connected by USB, exposed by macOS as capture devices (like QuickTime).
enum MobileDevices {
    /// Lets CoreMediaIO publish the screens of USB-connected iOS / iPadOS devices.
    static func enable() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    static func connected() -> [CameraRecorder.Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified)
            .devices.map { CameraRecorder.Device(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Records a connected iPhone/iPad screen (with its audio, plus an optional microphone) to a movie file.
@MainActor
final class DeviceCapture: NSObject {
    enum DeviceError: LocalizedError {
        case unavailable

        var errorDescription: String? { tr("device.unavailable") }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "mirecorder.device-session")
    private var finished = false
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var startUptime: TimeInterval?

    func start(deviceID: String, microphoneID: String?, to url: URL) async throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw DeviceError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw DeviceError.unavailable
        }
        session.addInput(input)
        // Optional narration on top of the device's own audio.
        if let microphoneID, let mic = AVCaptureDevice(uniqueID: microphoneID),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        session.addOutput(output)
        session.commitConfiguration()

        let session = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                session.startRunning()
                continuation.resume()
            }
        }
        output.startRecording(to: url, recordingDelegate: self)
    }

    func pause() {
        if output.isRecording, !output.isRecordingPaused { output.pauseRecording() }
    }

    func resume() {
        if output.isRecordingPaused { output.resumeRecording() }
    }

    func stop() async {
        if output.isRecording {
            output.stopRecording()
            if !finished { await withCheckedContinuation { finishContinuation = $0 } }
        }
        let session = session
        queue.async { session.stopRunning() }
    }

    private func didFinish() {
        finished = true
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

extension DeviceCapture: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in self.startUptime = now }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor in self.didFinish() }
    }
}
