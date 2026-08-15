import Foundation

final class StreamingAudioWorker: @unchecked Sendable {
    private let ringBuffer: RealtimeAudioRingBuffer
    private let channelCount: Int
    private let server: WebSocketAudioServer
    private let queue = DispatchQueue(label: "com.local.resonance432.streaming-audio-worker")
    private let stateLock = NSLock()
    private let chunkFrames = 1_024

    private var timer: DispatchSourceTimer?
    private var channelStorage: [UnsafeMutablePointer<Float>] = []
    private var channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var interleavedStorage: UnsafeMutablePointer<Float>?
    private var running = false
    private var _streamedFrames: UInt64 = 0

    init(
        ringBuffer: RealtimeAudioRingBuffer,
        channelCount: Int,
        server: WebSocketAudioServer
    ) {
        self.ringBuffer = ringBuffer
        self.channelCount = channelCount
        self.server = server

        channelPointers = .allocate(capacity: channelCount)
        interleavedStorage = .allocate(capacity: chunkFrames * channelCount)
        for channel in 0..<channelCount {
            let storage = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames)
            storage.initialize(repeating: 0, count: chunkFrames)
            channelStorage.append(storage)
            channelPointers?[channel] = storage
        }
        interleavedStorage?.initialize(repeating: 0, count: chunkFrames * channelCount)
    }

    deinit {
        stop()
        channelStorage.forEach { $0.deallocate() }
        channelPointers?.deallocate()
        interleavedStorage?.deallocate()
    }

    var streamedFrames: UInt64 {
        stateLock.withLock { _streamedFrames }
    }

    var droppedFrames: UInt64 {
        server.droppedAudioFrames
    }

    func start() {
        stateLock.withLock { running = true }
        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        newTimer.setEventHandler { [weak self] in
            self?.drainOnce()
        }
        timer = newTimer
        newTimer.resume()
    }

    func stop() {
        stateLock.withLock { running = false }
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func drainOnce() {
        guard stateLock.withLock({ running }),
              let channelPointers,
              let interleavedStorage else {
            return
        }

        let available = min(Int(ringBuffer.availableFrames), chunkFrames)
        guard available > 0 else {
            return
        }

        let framesRead = Int(ringBuffer.readChannels(
            channelPointers,
            channelCount: UInt(channelCount),
            frameCount: UInt(available)
        ))
        guard framesRead > 0 else {
            return
        }

        for frame in 0..<framesRead {
            for channel in 0..<channelCount {
                interleavedStorage[frame * channelCount + channel] = channelStorage[channel][frame]
            }
        }

        let byteCount = framesRead * channelCount * MemoryLayout<Float>.stride
        let pcm = Data(bytes: interleavedStorage, count: byteCount)
        if server.broadcastPCMChunk(pcm, frameCount: framesRead) {
            stateLock.withLock { _streamedFrames += UInt64(framesRead) }
        }
    }
}
