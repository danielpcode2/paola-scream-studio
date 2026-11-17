import AVFoundation

struct AudioDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    static func microphones() -> [AudioDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { AudioDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
}

/// Live input level of the selected microphone for the recording toolbar.
@MainActor
final class MicMonitor: ObservableObject {
    /// 0...1
    @Published private(set) var level: Double = 0

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "mirecorder.mic-monitor")
    private let sink = SampleSink()

    func start(deviceID: String?) {
        stop()
        guard let deviceID, let device = AVCaptureDevice(uniqueID: deviceID),
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(sink, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        self.session = session
        self.output = output
        queue.async { session.startRunning() }

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let session { queue.async { session.stopRunning() } }
        session = nil
        output = nil
        level = 0
    }

    private func poll() {
        let power = output?.connections.first?.audioChannels.first?.averagePowerLevel ?? -160
        level = min(max((Double(power) + 50) / 50, 0), 1)
    }

    private final class SampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {}
}
