import AudioToolbox
import Darwin

final class ResonancePassthroughDSP {
    private var signalsmithBridge: SignalsmithDSPBridge?
    private(set) var pitchCents = 0.0
    private var inputBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var inputChannelData: [UnsafeMutableRawPointer] = []
    private var inputChannelCounts: [UInt32] = []
    private var inputProcessingChannels: [UnsafePointer<Float>] = []
    private var outputProcessingChannels: [UnsafeMutablePointer<Float>] = []
    private var channelCount = 0
    private var maximumFrameCount = 0

    deinit {
        deallocateRenderResources()
    }

    func configure(sampleRate: Double, channelCount: Int) {
        let bridge = SignalsmithDSPBridge()
        bridge.configure(
            withSampleRate: sampleRate,
            channelCount: UInt(channelCount)
        )
        bridge.pitchCents = pitchCents
        signalsmithBridge = bridge
    }

    func setPitchCents(_ pitchCents: Double) {
        self.pitchCents = pitchCents
        signalsmithBridge?.pitchCents = pitchCents
    }

    func reset() {
        signalsmithBridge?.reset()
    }

    func allocateRenderResources(channelCount: Int, maximumFrameCount: Int) {
        deallocateRenderResources()

        self.channelCount = channelCount
        self.maximumFrameCount = maximumFrameCount

        let bufferListSize = MemoryLayout<AudioBufferList>.size
            + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.stride
        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawBufferList.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: bufferListSize
        )

        let bufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        bufferList.pointee.mNumberBuffers = UInt32(channelCount)

        let bytesPerChannel = maximumFrameCount * MemoryLayout<Float>.stride
        inputChannelData.reserveCapacity(channelCount)
        inputChannelCounts.reserveCapacity(channelCount)
        inputProcessingChannels.reserveCapacity(channelCount)
        outputProcessingChannels.reserveCapacity(channelCount)

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for channelIndex in 0..<channelCount {
            let channelData = UnsafeMutableRawPointer.allocate(
                byteCount: bytesPerChannel,
                alignment: MemoryLayout<Float>.alignment
            )
            inputChannelData.append(channelData)
            inputChannelCounts.append(1)
            inputProcessingChannels.append(
                UnsafePointer(channelData.assumingMemoryBound(to: Float.self))
            )
            outputProcessingChannels.append(
                channelData.assumingMemoryBound(to: Float.self)
            )
            buffers[channelIndex] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bytesPerChannel),
                mData: channelData
            )
        }

        inputBufferList = bufferList
    }

    func deallocateRenderResources() {
        for channelData in inputChannelData {
            channelData.deallocate()
        }
        inputChannelData.removeAll(keepingCapacity: false)
        inputChannelCounts.removeAll(keepingCapacity: false)
        inputProcessingChannels.removeAll(keepingCapacity: false)
        outputProcessingChannels.removeAll(keepingCapacity: false)

        if let inputBufferList {
            UnsafeMutableRawPointer(inputBufferList).deallocate()
            self.inputBufferList = nil
        }

        channelCount = 0
        maximumFrameCount = 0
    }

    func render(
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AUAudioFrameCount,
        outputBusNumber: Int,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        pullInputBlock: AURenderPullInputBlock?
    ) -> AUAudioUnitStatus {
        guard outputBusNumber == 0 else {
            return kAudioUnitErr_InvalidElement
        }

        guard let pullInputBlock else {
            return kAudioUnitErr_NoConnection
        }

        guard let inputBufferList,
              Int(frameCount) <= maximumFrameCount else {
            return kAudioUnitErr_TooManyFramesToProcess
        }

        let byteCount = Int(frameCount) * MemoryLayout<Float>.stride
        inputBufferList.pointee.mNumberBuffers = UInt32(channelCount)

        let inputBuffers = UnsafeMutableAudioBufferListPointer(inputBufferList)
        for channelIndex in 0..<channelCount {
            inputBuffers[channelIndex].mNumberChannels = inputChannelCounts[channelIndex]
            inputBuffers[channelIndex].mData = inputChannelData[channelIndex]
            inputBuffers[channelIndex].mDataByteSize = UInt32(byteCount)
        }

        var pullFlags: AudioUnitRenderActionFlags = []
        let pullStatus = pullInputBlock(
            &pullFlags,
            timestamp,
            frameCount,
            0,
            inputBufferList
        )

        guard pullStatus == noErr else {
            return pullStatus
        }

        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard inputBuffers.count >= channelCount,
              outputBuffers.count >= channelCount else {
            return kAudio_ParamError
        }

        for channelIndex in 0..<channelCount {
            guard inputBuffers[channelIndex].mData != nil,
                  let outputData = outputBuffers[channelIndex].mData else {
                return kAudio_ParamError
            }
            outputProcessingChannels[channelIndex] = outputData.assumingMemoryBound(to: Float.self)
            outputBuffers[channelIndex].mDataByteSize = UInt32(byteCount)
        }

        guard let signalsmithBridge else {
            return kAudioUnitErr_Uninitialized
        }

        let processed = inputProcessingChannels.withUnsafeBufferPointer { inputChannels in
            outputProcessingChannels.withUnsafeMutableBufferPointer { outputChannels in
                signalsmithBridge.processInputChannels(
                    inputChannels.baseAddress!,
                    outputChannels: outputChannels.baseAddress!,
                    channelCount: UInt(channelCount),
                    frameCount: UInt(frameCount)
                )
            }
        }

        guard processed else {
            return kAudio_ParamError
        }

        return noErr
    }
}
