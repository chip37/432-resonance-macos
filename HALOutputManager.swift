import AudioToolbox
import CoreAudio
import Darwin
import Foundation

enum HALOutputError: LocalizedError {
    case componentUnavailable
    case invalidHardwareFormat
    case sampleRateMismatch(processed: Double, output: Double)
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .componentUnavailable:
            return "The Apple HAL output Audio Unit is unavailable."
        case .invalidHardwareFormat:
            return "The selected output device does not expose a valid stereo hardware format."
        case .sampleRateMismatch(let processed, let output):
            return "Processed audio is \(processed) Hz, but External Headphones uses \(output) Hz. Sample-rate conversion is not enabled."
        case .coreAudio(let operation, let status):
            return "\(operation) failed with OSStatus \(status)."
        }
    }
}

final class HALOutputManager {
    fileprivate final class RenderState {
        let ringBuffer: RealtimeAudioRingBuffer
        var outputPeakBits: Int32 = 0

        init(ringBuffer: RealtimeAudioRingBuffer) {
            self.ringBuffer = ringBuffer
        }
    }

    private var audioUnit: AudioUnit?
    private var renderState: RenderState?
    private(set) var hardwareFormat = AudioStreamBasicDescription()
    private(set) var clientFormat = AudioStreamBasicDescription()
    private(set) var isRunning = false

    var underflowCount: UInt64 {
        renderState?.ringBuffer.underflowCount ?? 0
    }

    var outputPeak: Float {
        guard let renderState else { return 0 }
        let bits = OSAtomicAdd32Barrier(0, &renderState.outputPeakBits)
        return Float(bitPattern: UInt32(bitPattern: bits))
    }

    deinit {
        teardownIgnoringErrors()
    }

    static func outputSampleRate(deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &sampleRate
        )
        guard status == noErr, sampleRate > 0 else {
            throw HALOutputError.coreAudio(
                operation: "Reading the output-device sample rate",
                status: status
            )
        }
        return sampleRate
    }

    func configure(
        deviceID: AudioDeviceID,
        ringBuffer: RealtimeAudioRingBuffer,
        processedSampleRate: Double
    ) throws {
        try teardown()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw HALOutputError.componentUnavailable
        }

        var newAudioUnit: AudioUnit?
        try check(
            AudioComponentInstanceNew(component, &newAudioUnit),
            operation: "Creating the HAL output Audio Unit"
        )
        guard let newAudioUnit else {
            throw HALOutputError.componentUnavailable
        }

        do {
            var outputEnabled: UInt32 = 1
            try check(
                AudioUnitSetProperty(
                    newAudioUnit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output,
                    0,
                    &outputEnabled,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                operation: "Enabling HAL output"
            )

            var inputEnabled: UInt32 = 0
            try check(
                AudioUnitSetProperty(
                    newAudioUnit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Input,
                    1,
                    &inputEnabled,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                operation: "Disabling HAL input"
            )

            var selectedDeviceID = deviceID
            try check(
                AudioUnitSetProperty(
                    newAudioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &selectedDeviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                ),
                operation: "Assigning the HAL output device"
            )

            var deviceFormat = AudioStreamBasicDescription()
            var deviceFormatSize = UInt32(
                MemoryLayout<AudioStreamBasicDescription>.size
            )
            try check(
                AudioUnitGetProperty(
                    newAudioUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Output,
                    0,
                    &deviceFormat,
                    &deviceFormatSize
                ),
                operation: "Reading the HAL hardware format"
            )
            guard deviceFormat.mSampleRate > 0,
                  deviceFormat.mChannelsPerFrame >= 2 else {
                throw HALOutputError.invalidHardwareFormat
            }
            guard abs(deviceFormat.mSampleRate - processedSampleRate) < 0.5 else {
                throw HALOutputError.sampleRateMismatch(
                    processed: processedSampleRate,
                    output: deviceFormat.mSampleRate
                )
            }

            var stereoClientFormat = AudioStreamBasicDescription(
                mSampleRate: deviceFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat |
                    kAudioFormatFlagIsPacked |
                    kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try check(
                AudioUnitSetProperty(
                    newAudioUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    &stereoClientFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                operation: "Setting the HAL client format"
            )

            var negotiatedClientFormat = AudioStreamBasicDescription()
            var negotiatedFormatSize = UInt32(
                MemoryLayout<AudioStreamBasicDescription>.size
            )
            try check(
                AudioUnitGetProperty(
                    newAudioUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    &negotiatedClientFormat,
                    &negotiatedFormatSize
                ),
                operation: "Reading the HAL client format"
            )

            let state = RenderState(ringBuffer: ringBuffer)
            var callback = AURenderCallbackStruct(
                inputProc: halRingRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(state).toOpaque()
            )
            try check(
                AudioUnitSetProperty(
                    newAudioUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                operation: "Installing the HAL render callback"
            )

            try check(
                AudioUnitInitialize(newAudioUnit),
                operation: "Initializing the HAL output Audio Unit"
            )

            audioUnit = newAudioUnit
            renderState = state
            hardwareFormat = deviceFormat
            clientFormat = negotiatedClientFormat
        } catch {
            AudioComponentInstanceDispose(newAudioUnit)
            throw error
        }
    }

    func start() throws {
        guard let audioUnit else {
            throw HALOutputError.componentUnavailable
        }
        guard !isRunning else {
            return
        }
        try check(
            AudioOutputUnitStart(audioUnit),
            operation: "Starting the HAL output Audio Unit"
        )
        isRunning = true
    }

    func stop() throws {
        guard let audioUnit, isRunning else {
            return
        }
        try check(
            AudioOutputUnitStop(audioUnit),
            operation: "Stopping the HAL output Audio Unit"
        )
        isRunning = false
    }

    func teardown() throws {
        try stop()
        guard let audioUnit else {
            return
        }
        try check(
            AudioUnitUninitialize(audioUnit),
            operation: "Uninitializing the HAL output Audio Unit"
        )
        try check(
            AudioComponentInstanceDispose(audioUnit),
            operation: "Disposing the HAL output Audio Unit"
        )
        self.audioUnit = nil
        renderState = nil
        hardwareFormat = AudioStreamBasicDescription()
        clientFormat = AudioStreamBasicDescription()
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw HALOutputError.coreAudio(operation: operation, status: status)
        }
    }

    private func teardownIgnoringErrors() {
        if let audioUnit {
            if isRunning {
                AudioOutputUnitStop(audioUnit)
            }
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }
        audioUnit = nil
        renderState = nil
        isRunning = false
    }
}

private let halRingRenderCallback: AURenderCallback = {
    refCon,
    _,
    _,
    _,
    frameCount,
    outputData
    in
    guard let outputData else {
        return kAudio_ParamError
    }

    let state = Unmanaged<HALOutputManager.RenderState>
        .fromOpaque(refCon)
        .takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    guard buffers.count >= 2,
          let leftData = buffers[0].mData,
          let rightData = buffers[1].mData else {
        return kAudio_ParamError
    }

    let left = leftData.assumingMemoryBound(to: Float.self)
    let right = rightData.assumingMemoryBound(to: Float.self)
    let framesRead = state.ringBuffer.readLeftChannel(
        left,
        rightChannel: right,
        frameCount: UInt(frameCount)
    )
    var outputPeak: Float = 0
    for frame in 0..<Int(framesRead) {
        outputPeak = max(outputPeak, max(abs(left[frame]), abs(right[frame])))
    }
    let candidateBits = Int32(bitPattern: outputPeak.bitPattern)
    var currentBits = OSAtomicAdd32Barrier(0, &state.outputPeakBits)
    while candidateBits > currentBits {
        if OSAtomicCompareAndSwap32Barrier(
            currentBits, candidateBits, &state.outputPeakBits
        ) { break }
        currentBits = OSAtomicAdd32Barrier(0, &state.outputPeakBits)
    }
    if framesRead < frameCount {
        let missingFrameCount = Int(frameCount) - Int(framesRead)
        left.advanced(by: Int(framesRead)).initialize(
            repeating: 0,
            count: missingFrameCount
        )
        right.advanced(by: Int(framesRead)).initialize(
            repeating: 0,
            count: missingFrameCount
        )
    }

    let byteCount = UInt32(frameCount) * UInt32(MemoryLayout<Float>.size)
    for bufferIndex in 0..<2 {
        buffers[bufferIndex].mDataByteSize = byteCount
    }
    return noErr
}
