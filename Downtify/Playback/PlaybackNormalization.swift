import AVFoundation
import Foundation
import MediaToolbox

enum PlaybackNormalization: String, Codable {
    case off, normal, louder, maximum

    var targetDBFS: Double? {
        switch self {
        case .off: nil
        case .normal: -18
        case .louder: -14
        case .maximum: -10
        }
    }
}

struct PlaybackLevelMeasurement {
    static let peakLimit: Float = 0.97
    private var squareSum: Double = 0
    private var sampleCount = 0
    private(set) var peak: Float = 0

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples where sample.isFinite {
            peak = max(peak, abs(sample))
            let amplitude = Double(sample)
            squareSum += amplitude * amplitude
            sampleCount += 1
        }
    }

    func gain(for normalization: PlaybackNormalization) -> Float {
        guard let target = normalization.targetDBFS, sampleCount > 0, peak > 0 else { return 1 }
        let rms = sqrt(squareSum / Double(sampleCount))
        let targetGain = pow(10, target / 20) / rms
        return Float(min(targetGain, Double(Self.peakLimit) / Double(peak), 4))
    }

    static func process(_ samples: UnsafeMutableBufferPointer<Float>, gain: Float) {
        for index in samples.indices {
            let sample = samples[index] * gain
            samples[index] = sample.isFinite ? min(peakLimit, max(-peakLimit, sample)) : 0
        }
    }

    static func measure(_ stream: PlaybackStream) async throws -> Self? {
        // Decode a bounded copy separately so playback can start while measurement runs.
        guard stream.length > 0, stream.length <= 20_000_000 else { return nil }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(stream.fileExtension)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data().write(to: fileURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        let output = try FileHandle(forWritingTo: fileURL)
        defer { try? output.close() }
        var offset: Int64 = 0
        while offset < stream.length {
            try Task.checkCancellation()
            let end = min(offset + PlaybackCache.blockSize, stream.length)
            let bytes = try await stream.read(offset...(end - 1))
            try Task.checkCancellation()
            guard bytes.count == end - offset else { throw PlaybackFailure.invalidStream }
            try output.write(contentsOf: bytes)
            offset = end
        }
        try output.close()
        return try measure(fileURL)
    }

    static func measure(_ fileURL: URL) throws -> Self? {
        let audio = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard audio.length > 0, Double(audio.length) <= audio.processingFormat.sampleRate * 900,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8192) else {
            return nil
        }
        var result = Self()
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            try audio.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return nil }
            for channel in 0..<Int(buffer.format.channelCount) {
                result.add(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
            }
        }
        return result
    }
}

private final class PlaybackGainTap {
    let gain: Float
    var supportsFormat = false

    init(gain: Float) { self.gain = gain }

    static func create(gain: Float) -> MTAudioProcessingTap? {
        let state = Unmanaged.passRetained(PlaybackGainTap(gain: gain))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: state.toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in Unmanaged<PlaybackGainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                let state = Unmanaged<PlaybackGainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let format = format.pointee
                state.supportsFormat = format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
                    && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            },
            unprepare: nil,
            process: { tap, count, _, buffers, countOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, count, buffers, flagsOut, nil, countOut)
                guard status == noErr, countOut.pointee > 0 else { countOut.pointee = 0; return }
                let state = Unmanaged<PlaybackGainTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard state.supportsFormat else { return }
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = buffer.mData else { continue }
                    let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
                    let samples = min(capacity, countOut.pointee * Int(buffer.mNumberChannels))
                    PlaybackLevelMeasurement.process(
                        UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: samples),
                        gain: state.gain
                    )
                }
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr else {
            state.release()
            return nil
        }
        return tap
    }
}

extension PlaybackLevelMeasurement {
    func audioMix(for track: AVAssetTrack, normalization: PlaybackNormalization) -> AVAudioMix? {
        guard normalization != .off, let tap = PlaybackGainTap.create(gain: gain(for: normalization)) else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}
