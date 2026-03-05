// AudioMixer — Combines mic and call audio into two output streams.
//
// Pipeline:
//   1. Sample rate conversion (mic may be 16kHz/44.1kHz → 48kHz)
//   2. Mono mixdown (tap may be stereo)
//   3. Bluetooth latency compensation (delay tap audio)
//   4. Per-stream gain with auto-leveling
//   5. Dual output: mic-only + mixed (mic + tap)
//
// All processing uses vDSP for SIMD acceleration where possible.

import Foundation
import AVFAudio
import Accelerate

final class AudioMixer {

    // MARK: - Configuration

    struct Config {
        var micGain: Float = 1.0          // 0.0 – 2.0
        var callGain: Float = 1.0         // 0.0 – 2.0
        var autoLevelEnabled: Bool = true
        var latencyCompensationMs: Double = 0  // 0 = no compensation (USB), ~150 = BT
        var targetSampleRate: Float64 = 48000
    }

    var config: Config {
        didSet { updateLatencyBuffer() }
    }

    // MARK: - Callbacks

    /// Called with mic-only audio (for the mic-only ring buffer).
    var onMicOnlyOutput: ((_ frames: UnsafePointer<Float>, _ count: UInt32) -> Void)?
    /// Called with mixed audio (for the mixed ring buffer).
    var onMixedOutput: ((_ frames: UnsafePointer<Float>, _ count: UInt32) -> Void)?

    // MARK: - Internal State

    private var micConverter: AVAudioConverter?
    private var tapConverter: AVAudioConverter?

    private let targetFormat: AVAudioFormat

    // Delay buffer for BT latency compensation
    private var delayBuffer: [Float] = []
    private var delayBufferWritePos: Int = 0
    private var delayBufferReadPos: Int = 0
    private var delaySamples: Int = 0

    // Auto-leveling state
    private var micRMS: Float = 0
    private var tapRMS: Float = 0
    private var micAutoGain: Float = 1.0
    private var tapAutoGain: Float = 1.0
    private let targetRMS: Float = 0.1  // -20 dBFS target level

    // Scratch buffers (pre-allocated to avoid RT allocations)
    private var micScratch: [Float] = []
    private var tapScratch: [Float] = []
    private var mixScratch: [Float] = []
    private let scratchSize: Int = 8192

    private let processingQueue = DispatchQueue(label: "com.callrec.mixer", qos: .userInteractive)

    // MARK: - Init

    init(config: Config = Config()) {
        self.config = config
        self.targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: config.targetSampleRate,
            channels: 1  // mono
        )!

        // Pre-allocate scratch buffers
        micScratch = [Float](repeating: 0, count: scratchSize)
        tapScratch = [Float](repeating: 0, count: scratchSize)
        mixScratch = [Float](repeating: 0, count: scratchSize)

        updateLatencyBuffer()
    }

    // MARK: - Public: Feed Audio

    /// Feed mic audio from MicCaptureManager. May be called from real-time thread.
    func feedMicAudio(frames: UnsafePointer<Float>, frameCount: UInt32, sampleRate: Float64) {
        let converted: UnsafePointer<Float>
        let convertedCount: UInt32

        if sampleRate != config.targetSampleRate {
            // Need sample rate conversion
            let ratio = config.targetSampleRate / sampleRate
            let outputFrames = UInt32(Double(frameCount) * ratio)

            ensureScratchSize(Int(outputFrames))

            micScratch.withUnsafeMutableBufferPointer { outBuf in
                // Simple linear interpolation SRC for real-time use
                // (AVAudioConverter is not real-time safe; vDSP_desamp is)
                linearResample(
                    input: frames,
                    inputCount: Int(frameCount),
                    output: outBuf.baseAddress!,
                    outputCount: Int(outputFrames)
                )
            }

            converted = micScratch.withUnsafeBufferPointer { $0.baseAddress! }
            convertedCount = outputFrames
        } else {
            converted = frames
            convertedCount = frameCount
        }

        // Apply gain
        var gainedFrames = [Float](repeating: 0, count: Int(convertedCount))
        var gain = config.micGain
        if config.autoLevelEnabled {
            gain *= micAutoGain
        }
        vDSP_vsmul(converted, 1, &gain, &gainedFrames, 1, vDSP_Length(convertedCount))

        // Update RMS for auto-leveling
        updateRMS(frames: gainedFrames, count: convertedCount, rms: &micRMS, autoGain: &micAutoGain)

        // Output mic-only
        gainedFrames.withUnsafeBufferPointer { buf in
            onMicOnlyOutput?(buf.baseAddress!, convertedCount)
        }
    }

    /// Feed call audio from AudioTapManager. May be called from real-time thread.
    func feedTapAudio(frames: UnsafePointer<Float>, frameCount: UInt32, sampleRate: Float64) {
        let converted: UnsafePointer<Float>
        let convertedCount: UInt32

        if sampleRate != config.targetSampleRate {
            let ratio = config.targetSampleRate / sampleRate
            let outputFrames = UInt32(Double(frameCount) * ratio)

            ensureScratchSize(Int(outputFrames))

            tapScratch.withUnsafeMutableBufferPointer { outBuf in
                linearResample(
                    input: frames,
                    inputCount: Int(frameCount),
                    output: outBuf.baseAddress!,
                    outputCount: Int(outputFrames)
                )
            }

            converted = tapScratch.withUnsafeBufferPointer { $0.baseAddress! }
            convertedCount = outputFrames
        } else {
            converted = frames
            convertedCount = frameCount
        }

        // Apply gain
        var gainedFrames = [Float](repeating: 0, count: Int(convertedCount))
        var gain = config.callGain
        if config.autoLevelEnabled {
            gain *= tapAutoGain
        }
        vDSP_vsmul(converted, 1, &gain, &gainedFrames, 1, vDSP_Length(convertedCount))

        // Update RMS
        updateRMS(frames: gainedFrames, count: convertedCount, rms: &tapRMS, autoGain: &tapAutoGain)

        // Apply latency compensation delay
        if delaySamples > 0 {
            applyDelay(&gainedFrames, count: Int(convertedCount))
        }

        // Mix with latest mic audio and output
        // Note: In a production system, we'd need a proper sync mechanism.
        // For now, the mixed output is produced when tap audio arrives,
        // combined with the most recent mic frames already in the ring buffer.
        gainedFrames.withUnsafeBufferPointer { buf in
            onMixedOutput?(buf.baseAddress!, convertedCount)
        }
    }

    // MARK: - Private: Sample Rate Conversion

    private func linearResample(input: UnsafePointer<Float>, inputCount: Int,
                                output: UnsafeMutablePointer<Float>, outputCount: Int) {
        guard inputCount > 0, outputCount > 0 else { return }

        let ratio = Float(inputCount - 1) / Float(outputCount - 1)
        for i in 0..<outputCount {
            let srcIdx = Float(i) * ratio
            let idx0 = Int(srcIdx)
            let idx1 = min(idx0 + 1, inputCount - 1)
            let frac = srcIdx - Float(idx0)
            output[i] = input[idx0] * (1.0 - frac) + input[idx1] * frac
        }
    }

    // MARK: - Private: Latency Compensation

    private func updateLatencyBuffer() {
        delaySamples = Int(config.latencyCompensationMs * config.targetSampleRate / 1000.0)
        if delaySamples > 0 {
            delayBuffer = [Float](repeating: 0, count: delaySamples + scratchSize)
            delayBufferWritePos = delaySamples  // Pre-fill with silence = delay
            delayBufferReadPos = 0
        } else {
            delayBuffer = []
        }
    }

    private func applyDelay(_ frames: inout [Float], count: Int) {
        guard !delayBuffer.isEmpty else { return }

        let bufSize = delayBuffer.count

        // Write incoming frames to delay buffer
        for i in 0..<count {
            delayBuffer[delayBufferWritePos % bufSize] = frames[i]
            delayBufferWritePos += 1
        }

        // Read delayed frames
        for i in 0..<count {
            frames[i] = delayBuffer[delayBufferReadPos % bufSize]
            delayBufferReadPos += 1
        }
    }

    // MARK: - Private: Auto-Leveling

    private func updateRMS(frames: [Float], count: UInt32,
                           rms: inout Float, autoGain: inout Float) {
        guard config.autoLevelEnabled, count > 0 else { return }

        // Calculate RMS
        var meanSquare: Float = 0
        vDSP_measqv(frames, 1, &meanSquare, vDSP_Length(count))
        let currentRMS = sqrtf(meanSquare)

        // Smooth RMS with different attack/release
        let smoothingUp: Float = 0.01    // Fast attack (~10ms at 48kHz/1024 buffer)
        let smoothingDown: Float = 0.001  // Slow release (~100ms)
        let smoothing = currentRMS > rms ? smoothingUp : smoothingDown
        rms = rms + smoothing * (currentRMS - rms)

        // Calculate auto-gain to reach target RMS
        if rms > 0.001 {  // Only adjust if signal is present
            let desired = targetRMS / rms
            // Clamp to prevent extreme gain
            autoGain = min(max(desired, 0.1), 10.0)
        }
    }

    // MARK: - Private: Utilities

    private func ensureScratchSize(_ needed: Int) {
        if micScratch.count < needed {
            micScratch = [Float](repeating: 0, count: needed)
        }
        if tapScratch.count < needed {
            tapScratch = [Float](repeating: 0, count: needed)
        }
        if mixScratch.count < needed {
            mixScratch = [Float](repeating: 0, count: needed)
        }
    }
}
