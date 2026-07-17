import AudioToolbox
import AVFoundation

final class ResonanceAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharCode("rpas"),
        componentManufacturer: fourCharCode("r432"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private let dsp = ResonancePassthroughDSP()
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override var inputBusses: AUAudioUnitBusArray {
        inputBusArray
    }

    override var outputBusses: AUAudioUnitBusArray {
        outputBusArray
    }

    override var canProcessInPlace: Bool {
        true
    }

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let defaultFormat = try Self.makeInitialBusFormat()

        inputBus = try AUAudioUnitBus(format: defaultFormat)
        outputBus = try AUAudioUnitBus(format: defaultFormat)
        inputBus.maximumChannelCount = 64
        outputBus.maximumChannelCount = 64
        inputBus.shouldAllocateBuffer = false
        outputBus.shouldAllocateBuffer = false

        try super.init(componentDescription: componentDescription, options: options)

        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
    }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            print("432 Resonance AU rejected proposed bus format: \(Self.formatDescription(format))")
            return false
        }

        print("432 Resonance AU accepted proposed bus format: \(Self.formatDescription(format))")
        return true
    }

    override func allocateRenderResources() throws {
        let inputFormat = inputBus.format
        let outputFormat = outputBus.format
        print("432 Resonance AU allocateRenderResources input bus format: \(Self.formatDescription(inputFormat))")
        print("432 Resonance AU allocateRenderResources output bus format: \(Self.formatDescription(outputFormat))")
        print("432 Resonance AU allocateRenderResources sampleRate: input=\(inputFormat.sampleRate), output=\(outputFormat.sampleRate)")
        print("432 Resonance AU allocateRenderResources channelCount: input=\(inputFormat.channelCount), output=\(outputFormat.channelCount)")
        print("432 Resonance AU allocateRenderResources commonFormat: input=\(inputFormat.commonFormat), output=\(outputFormat.commonFormat)")
        print("432 Resonance AU allocateRenderResources interleaved: input=\(inputFormat.isInterleaved), output=\(outputFormat.isInterleaved)")
        print("432 Resonance AU passthrough negotiated input channel count: \(inputFormat.channelCount)")
        print("432 Resonance AU passthrough negotiated output channel count: \(outputFormat.channelCount)")
        print("432 Resonance AU passthrough canProcessInPlace: \(canProcessInPlace)")
        print("432 Resonance AU passthrough input shouldAllocateBuffer: \(inputBus.shouldAllocateBuffer)")
        print("432 Resonance AU passthrough output shouldAllocateBuffer: \(outputBus.shouldAllocateBuffer)")
        print("432 Resonance AU passthrough input/output bus formats match: \(Self.formatsMatch(inputFormat, outputFormat))")

        guard inputFormat.commonFormat == .pcmFormatFloat32,
              outputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved,
              !outputFormat.isInterleaved else {
            throw Self.formatError("ResonanceAudioUnit requires non-interleaved Float32 PCM.")
        }

        guard inputFormat.sampleRate > 0,
              outputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              outputFormat.channelCount > 0 else {
            throw Self.formatError("ResonanceAudioUnit received an invalid sample rate or channel count.")
        }

        guard inputFormat.sampleRate == outputFormat.sampleRate else {
            throw Self.formatError("ResonanceAudioUnit input and output sample rates must match.")
        }

        guard inputFormat.channelCount == outputFormat.channelCount else {
            throw Self.formatError("ResonanceAudioUnit input and output channel counts must match.")
        }

        try super.allocateRenderResources()
        dsp.configure(sampleRate: outputFormat.sampleRate)
    }

    override func deallocateRenderResources() {
        super.deallocateRenderResources()
    }

    override func reset() {
        dsp.reset()
        super.reset()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let dsp = self.dsp
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, _, pullInputBlock in
            dsp.render(
                actionFlags: actionFlags,
                timestamp: timestamp,
                frameCount: frameCount,
                outputBusNumber: outputBusNumber,
                outputData: outputData,
                pullInputBlock: pullInputBlock
            )
        }
    }

    private static func formatError(_ message: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kAudioUnitErr_FormatNotSupported),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func makeInitialBusFormat() throws -> AVAudioFormat {
        // AUAudioUnitBus requires an initial format. The host replaces this during graph connection.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        ) else {
            throw formatError("Could not create the initial ResonanceAudioUnit bus format.")
        }

        return format
    }

    private static func formatDescription(_ format: AVAudioFormat) -> String {
        "sampleRate=\(format.sampleRate), channels=\(format.channelCount), commonFormat=\(format.commonFormat), interleaved=\(format.isInterleaved), raw=\(format)"
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat &&
        lhs.sampleRate == rhs.sampleRate &&
        lhs.channelCount == rhs.channelCount &&
        lhs.isInterleaved == rhs.isInterleaved
    }
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { partialResult, character in
        (partialResult << 8) + FourCharCode(character)
    }
}
