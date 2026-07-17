import AudioToolbox
import AVFoundation
import Darwin

private let DEBUG_TEST_TONE = false

final class ResonancePassthroughDSP {
    private let toneFrequency = 440.0
    private let toneAmplitude: Float = 0.05
    private var phase = 0.0
    private var phaseIncrement = 0.0

    func configure(sampleRate: Double) {
        phase = 0.0
        phaseIncrement = 2.0 * Double.pi * toneFrequency / sampleRate
    }

    func reset() {
        phase = 0.0
    }

    func render(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AUAudioFrameCount,
        outputBusNumber: Int,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        pullInputBlock: AURenderPullInputBlock?
    ) -> AUAudioUnitStatus {
        guard outputBusNumber == 0 else {
            return kAudioUnitErr_InvalidElement
        }

        if DEBUG_TEST_TONE {
            return renderTestTone(frameCount: frameCount, outputData: outputData)
        }

        guard let pullInputBlock else {
            return kAudioUnitErr_NoConnection
        }

        return pullInputBlock(
            actionFlags,
            timestamp,
            frameCount,
            0,
            outputData
        )
    }

    private func renderTestTone(
        frameCount: AUAudioFrameCount,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> AUAudioUnitStatus {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        let frameCount = Int(frameCount)

        for bufferIndex in 0..<outputBuffers.count {
            guard let rawData = outputBuffers[bufferIndex].mData else {
                return kAudio_ParamError
            }

            let samples = rawData.assumingMemoryBound(to: Float.self)
            var localPhase = phase

            for frameIndex in 0..<frameCount {
                samples[frameIndex] = Float(sin(localPhase)) * toneAmplitude
                localPhase += phaseIncrement
                if localPhase >= 2.0 * Double.pi {
                    localPhase -= 2.0 * Double.pi
                }
            }
        }

        phase += phaseIncrement * Double(frameCount)
        phase.formTruncatingRemainder(dividingBy: 2.0 * Double.pi)
        return noErr
    }
}
