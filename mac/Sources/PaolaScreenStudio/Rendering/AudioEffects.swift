import AVFoundation
import MediaToolbox

enum AudioEffects {
    /// Short synthesized mouse-click sound (generated once, no bundled asset).
    static func clickSoundURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "mirecorder-click-v1.caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let frames = AVAudioFrameCount(sampleRate * 0.045)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        var seed: UInt32 = 12345
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            let tone = sin(2 * .pi * 2_400 * t)
            let envelope = exp(-t * 140)
            samples[i] = Float((0.55 * noise + 0.45 * tone) * envelope * 0.8)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// Gain that brings the recording to a consistent loudness (about -20 dBFS RMS of speech).
    static func normalizationGain(for asset: AVAsset) async -> Double {
        let key = (asset as? AVURLAsset)?.url.path ?? ObjectIdentifier(asset).debugDescription
        if let cached = await GainCache.shared.value(for: key) { return cached }
        let gain = await measureGain(asset)
        await GainCache.shared.store(gain, for: key)
        return gain
    }

    private static func measureGain(_ asset: AVAsset) async -> Double {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let reader = try? AVAssetReader(asset: asset)
        else { return 1 }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return 1 }
        var sum = 0.0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for value in data where abs(value) > 0.003 { // ignore silence
                sum += Double(value * value)
                count += 1
            }
        }
        guard count > 1_000 else { return 1 }
        let rms = (sum / Double(count)).squareRoot()
        return min(max(0.1 / rms, 0.5), 8)
    }

    /// Peak level per bucket (0...1) across all audio tracks, for drawing a waveform.
    static func waveform(for asset: AVAsset, buckets: Int = 1200) async -> [Float] {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let duration = try? await asset.load(.duration).seconds, duration > 0,
              let reader = try? AVAssetReader(asset: asset)
        else { return [] }
        let sampleRate = 8_000.0 // lowest rate AVAssetReader accepts for LPCM output
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }
        let perBucket = max(1, Int(duration * sampleRate) / buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for value in data {
                let bucket = min(index / perBucket, buckets - 1)
                peaks[bucket] = max(peaks[bucket], abs(value))
                index += 1
            }
        }
        let maxPeak = max(peaks.max() ?? 0, 0.0001)
        return peaks.map { min(1, $0 / maxPeak) }
    }

    /// Audio mix for a built timeline: recording volume (+ normalization and noise gate),
    /// click sounds and background music with a fade-out.
    static func makeMix(
        recordingTracks: [AVCompositionTrack],
        clickTrack: AVCompositionTrack?,
        musicTrack: AVCompositionTrack?,
        settings: EditSettings,
        normalizationGain: Double,
        totalDuration: CMTime
    ) -> AVAudioMix {
        var parameters: [AVMutableAudioMixInputParameters] = []
        let recordingGain = Float(settings.recordingVolume * (settings.normalizeAudio ? normalizationGain : 1))
        for track in recordingTracks {
            let input = AVMutableAudioMixInputParameters(track: track)
            input.setVolume(recordingGain, at: .zero)
            if settings.noiseReduction { input.audioTapProcessor = NoiseGate.makeTap() }
            parameters.append(input)
        }
        if let clickTrack {
            let input = AVMutableAudioMixInputParameters(track: clickTrack)
            input.setVolume(0.7, at: .zero)
            parameters.append(input)
        }
        if let musicTrack {
            let input = AVMutableAudioMixInputParameters(track: musicTrack)
            let volume = Float(settings.musicVolume)
            input.setVolume(volume, at: .zero)
            let fade = CMTime(seconds: min(2, totalDuration.seconds / 4), preferredTimescale: 600)
            input.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: totalDuration - fade, duration: fade))
            parameters.append(input)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }
}

private actor GainCache {
    static let shared = GainCache()
    private var values: [String: Double] = [:]

    func value(for key: String) -> Double? { values[key] }
    func store(_ value: Double, for key: String) { values[key] = value }
}

/// Noise reduction for voice: 80 Hz high-pass (rumble, hum) + a soft noise gate that lowers
/// background noise between words by ~16 dB. Runs as an audio tap in preview and export.
enum NoiseGate {
    final class State {
        var sampleRate: Double = 48_000
        var isFloat = true
        var isNonInterleaved = true
        var channels = 2
        var envelope: Float = 0
        var gain: Float = 1
        var previousInput: [Float] = []
        var previousOutput: [Float] = []

        func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
            guard isFloat, frames > 0 else { return }
            let channelCount = isNonInterleaved ? buffers.count : channels
            if previousInput.count != channelCount {
                previousInput = Array(repeating: 0, count: channelCount)
                previousOutput = Array(repeating: 0, count: channelCount)
            }
            let dt = 1 / Float(sampleRate)
            let rc = 1 / (2 * Float.pi * 80)
            let alpha = rc / (rc + dt)
            let attack = exp(-1 / (Float(sampleRate) * 0.005))
            let release = exp(-1 / (Float(sampleRate) * 0.150))
            let gainAttack = exp(-1 / (Float(sampleRate) * 0.004))
            let gainRelease = exp(-1 / (Float(sampleRate) * 0.090))
            let threshold: Float = 0.006 // about -44 dBFS
            let floor: Float = 0.16 // about -16 dB

            func sample(_ channel: Int, _ frame: Int) -> UnsafeMutablePointer<Float>? {
                if isNonInterleaved {
                    guard channel < buffers.count, let data = buffers[channel].mData else { return nil }
                    return data.assumingMemoryBound(to: Float.self) + frame
                }
                guard let data = buffers[0].mData else { return nil }
                return data.assumingMemoryBound(to: Float.self) + frame * channelCount + channel
            }

            for frame in 0..<frames {
                var level: Float = 0
                for channel in 0..<channelCount {
                    guard let pointer = sample(channel, frame) else { continue }
                    let input = pointer.pointee
                    let output = alpha * (previousOutput[channel] + input - previousInput[channel])
                    previousInput[channel] = input
                    previousOutput[channel] = output
                    pointer.pointee = output
                    level = max(level, abs(output))
                }
                let envelopeCoefficient = level > envelope ? attack : release
                envelope = envelopeCoefficient * envelope + (1 - envelopeCoefficient) * level
                let target: Float = envelope > threshold ? 1 : floor
                let gainCoefficient = target > gain ? gainAttack : gainRelease
                gain = gainCoefficient * gain + (1 - gainCoefficient) * target
                for channel in 0..<channelCount {
                    sample(channel, frame)?.pointee *= gain
                }
            }
        }
    }

    static func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil,
            init: { _, _, storageOut in
                storageOut.pointee = Unmanaged.passRetained(State()).toOpaque()
            },
            finalize: { tap in
                Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let description = format.pointee
                state.sampleRate = description.mSampleRate
                state.isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0 && description.mBitsPerChannel == 32
                state.isNonInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                state.channels = Int(description.mChannelsPerFrame)
            },
            unprepare: { _ in },
            process: { tap, frameCount, _, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, framesOut)
                guard status == noErr else { return }
                let state = Unmanaged<State>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                state.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        return status == noErr ? tap : nil
    }
}
