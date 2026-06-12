import AVFoundation
import CoreMedia
import Foundation

/// Speech-only mic tap. Sets the system default input device but does not rebind the audio unit (avoids -10875).
final class VoiceAudioCapture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.clippy.voice.audio", qos: .userInitiated)
    private var pcmHandler: ((AVAudioPCMBuffer) -> Void)?
    private var isRunning = false

    func start(preferredUID: String, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CaptureError.unavailable)
                    return
                }
                do {
                    self.pcmHandler = onBuffer
                    try self.startLocked(preferredUID: preferredUID)
                    continuation.resume()
                } catch {
                    self.pcmHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.stopLocked()
                continuation.resume()
            }
        }
    }

    private func startLocked(preferredUID: String) throws {
        stopLocked()

        if !preferredUID.isEmpty {
            AudioDeviceManager.setSystemDefaultInputDevice(uid: preferredUID)
            Thread.sleep(forTimeInterval: 0.15)
        }

        let input = engine.inputNode
        input.volume = 0

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.invalidFormat
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.pcmHandler?(buffer)
        }

        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    private func stopLocked() {
        pcmHandler = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        isRunning = false
    }

    enum CaptureError: LocalizedError {
        case unavailable
        case invalidFormat

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Voice capture unavailable."
            case .invalidFormat: return "Microphone format is invalid — try System Default in Settings."
            }
        }
    }
}

enum CaptureAudioSampleConverter {
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferIsValid(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        _ = blockBuffer
        return pcmBuffer
    }
}

final class SpeechAudioConverter {
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
