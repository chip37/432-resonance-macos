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
        false
    }

    func setPitchCents(_ pitchCents: Double) {
        dsp.setPitchCents(pitchCents)
    }

    func processedRingSnapshot() -> ProcessedAudioRingSnapshot {
        dsp.processedRingSnapshot()
    }

    func processedRingAccess() -> (RealtimeAudioRingBuffer, Double, Int)? {
        dsp.processedRingAccess()
    }

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        let initialFormat = try Self.makeInitialBusFormat()

        inputBus = try AUAudioUnitBus(format: initialFormat)
        outputBus = try AUAudioUnitBus(format: initialFormat)
        inputBus.maximumChannelCount = 64
        outputBus.maximumChannelCount = 64
        inputBus.shouldAllocateBuffer = true
        outputBus.shouldAllocateBuffer = false

        try super.init(componentDescription: componentDescription, options: options)

        inputBusArray = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .input,
            busses: [inputBus]
        )
        outputBusArray = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .output,
            busses: [outputBus]
        )
    }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        format.commonFormat == .pcmFormatFloat32 &&
        !format.isInterleaved &&
        format.sampleRate > 0 &&
        format.channelCount > 0
    }

    override func allocateRenderResources() throws {
        let inputFormat = inputBus.format
        let outputFormat = outputBus.format

        guard Self.formatsMatch(inputFormat, outputFormat) else {
            throw Self.formatError(
                "ResonanceAudioUnit requires matching input and output formats."
            )
        }

        guard inputFormat.commonFormat == .pcmFormatFloat32,
              !inputFormat.isInterleaved,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0 else {
            throw Self.formatError(
                "ResonanceAudioUnit requires non-interleaved Float32 PCM."
            )
        }

        dsp.configure(
            sampleRate: inputFormat.sampleRate,
            channelCount: Int(inputFormat.channelCount)
        )
        dsp.allocateRenderResources(
            channelCount: Int(inputFormat.channelCount),
            maximumFrameCount: Int(maximumFramesToRender)
        )

        do {
            try super.allocateRenderResources()
        } catch {
            dsp.deallocateRenderResources()
            throw error
        }
    }

    override func deallocateRenderResources() {
        dsp.deallocateRenderResources()
        super.deallocateRenderResources()
    }

    override func reset() {
        super.reset()
        dsp.reset()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let dsp = self.dsp

        return { _, timestamp, frameCount, outputBusNumber, outputData, _, pullInputBlock in
            dsp.render(
                timestamp: timestamp,
                frameCount: frameCount,
                outputBusNumber: outputBusNumber,
                outputData: outputData,
                pullInputBlock: pullInputBlock
            )
        }
    }

    private static func makeInitialBusFormat() throws -> AVAudioFormat {
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

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat &&
        lhs.sampleRate == rhs.sampleRate &&
        lhs.channelCount == rhs.channelCount &&
        lhs.isInterleaved == rhs.isInterleaved
    }

    private static func formatError(_ message: String) -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(kAudioUnitErr_FormatNotSupported),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { partialResult, character in
        (partialResult << 8) + FourCharCode(character)
    }
}
