import AVFoundation
import Foundation

private let DEBUG_STREAMING = false
private let DEBUG_AUDIO_TAP = false

enum AudioEngineError: LocalizedError {
    case permissionDenied
    case missingInputDevice
    case missingOutputDevice
    case missingBlackHole
    case startupFailure(String)
    case deviceProblem(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is off. Open System Settings > Privacy & Security > Microphone and allow 432 Resonance."
        case .missingInputDevice:
            return "No input device is available. Connect an audio input device or install/select BlackHole 2ch."
        case .missingOutputDevice:
            return "No output device is available. Connect speakers, headphones, or another output device."
        case .missingBlackHole:
            return "BlackHole was not found. The app can still use another input, but BlackHole 2ch is expected for system-audio passthrough."
        case .startupFailure(let reason):
            return "Audio processing could not start: \(reason)"
        case .deviceProblem(let reason):
            return "Audio device problem: \(reason)"
        }
    }
}

@MainActor
final class AudioEngineManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Idle"
    @Published private(set) var errorMessage = ""

    private var engine: AVAudioEngine?
    private var halOutputManager: HALOutputManager?
    private var fixedRateConverter: FixedRateAudioConverter?
    private var dspProcessor: DSPProcessor?
    private var webSocketAudioServer: WebSocketAudioServer?
    private var isStarting = false

    func requestMicrophonePermission() async -> Bool {
        let authorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("432 Resonance microphone authorization status: \(authorizationStatusLogName(authorizationStatus))")

        switch authorizationStatus {
        case .authorized:
            print("432 Resonance microphone permission request made: false")
            print("432 Resonance microphone permission result: granted=true")
            return true
        case .notDetermined:
            print("432 Resonance microphone permission request made: true")
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    print("432 Resonance microphone permission result: granted=\(granted)")
                    continuation.resume(returning: granted)
                }
            }
            return granted
        case .denied, .restricted:
            print("432 Resonance microphone permission request made: false")
            print("432 Resonance microphone permission result: granted=false")
            return false
        @unknown default:
            print("432 Resonance microphone permission request made: false")
            print("432 Resonance microphone permission result: unknown authorization status; startup will stop safely.")
            return false
        }
    }

    func start(settings: SettingsModel, deviceManager: DeviceManager) async {
        guard !isStarting else {
            print("432 Resonance diagnostic: start ignored because startup is already in progress.")
            return
        }

        isStarting = true
        defer { isStarting = false }

        guard !isRunning else {
            print("432 Resonance diagnostic: start ignored because engine is already running.")
            return
        }

        if engine != nil {
            print("432 Resonance lifecycle: found stale engine before start; stopping it before rebuilding.")
            stopEngine()
        }

        errorMessage = ""
        statusMessage = "Checking microphone permission..."

        let hasPermission = await requestMicrophonePermission()
        guard hasPermission else {
            present(.permissionDenied)
            return
        }

        deviceManager.refreshDevices()

        print("432 Resonance diagnostic: selected UI input is \(deviceDescription(settings.selectedInputDeviceID, in: deviceManager.inputDevices)); diagnostic mode will use current macOS default input.")
        print("432 Resonance diagnostic: selected UI output is \(deviceDescription(settings.selectedOutputDeviceID, in: deviceManager.outputDevices)); diagnostic mode will use current macOS default output.")

        guard let inputID = deviceManager.defaultInputDeviceID() else {
            present(.missingInputDevice)
            return
        }

        guard let outputID = deviceManager.defaultOutputDeviceID() else {
            present(.missingOutputDevice)
            return
        }

        guard let externalHeadphonesID = deviceManager.outputDevices.first(where: {
            $0.displayName.compare(
                "External Headphones",
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        })?.id else {
            present(.deviceProblem("External Headphones is not available."))
            return
        }

        if !deviceManager.hasBlackHoleInput {
            errorMessage = AudioEngineError.missingBlackHole.localizedDescription
        }

        do {
            statusMessage = "Preparing current system devices..."
            let inputName = deviceManager.inputDevices.first { $0.id == inputID }?.displayName ?? "Device \(inputID)"
            let outputName = deviceManager.outputDevices.first { $0.id == outputID }?.displayName ?? "Device \(outputID)"
            print("432 Resonance selected input device: current macOS default -> \(inputName) [\(inputID)]")
            print("432 Resonance selected output device: current macOS default -> \(outputName) [\(outputID)]")
            print("432 Resonance pitch value: \(settings.pitchShiftCents) cents")
            print("432 Resonance diagnostic: skipping CoreAudio default-device changes.")
            try await startEngine(
                pitchShiftCents: settings.pitchShiftCents,
                bypassed: settings.isBypassed,
                externalHeadphonesID: externalHeadphonesID
            )
            isRunning = true
            statusMessage = settings.isBypassed ? "Running in bypass" : "Processing at \(settings.pitchShiftCents) cents"
        } catch let error as AudioEngineError {
            stopEngine()
            present(error)
        } catch {
            stopEngine()
            present(.startupFailure(error.localizedDescription))
        }
    }

    func stop() {
        stopEngine()
    }

    func stopEngine() {
        if let halOutputManager {
            do {
                try halOutputManager.stop()
            } catch {
                print("432 Resonance AUHAL stop error: \(error.localizedDescription)")
            }
            do {
                try halOutputManager.teardown()
            } catch {
                print("432 Resonance AUHAL teardown error: \(error.localizedDescription)")
            }
            self.halOutputManager = nil
        }
        fixedRateConverter?.stop()
        fixedRateConverter?.teardown()
        fixedRateConverter = nil

        guard let activeEngine = engine else {
            print("432 Resonance lifecycle: stop requested with no active engine.")
            isRunning = false
            statusMessage = "Stopped"
            return
        }

        print("432 Resonance lifecycle: stopping active engine \(engineIdentity(activeEngine)). isRunningBeforeStop=\(activeEngine.isRunning)")

        if DEBUG_AUDIO_TAP {
            dspProcessor?.timePitch.removeTap(onBus: 0)
        }

        webSocketAudioServer?.stop()
        activeEngine.stop()
        print("432 Resonance lifecycle: engine \(engineIdentity(activeEngine)) isRunning after stop=\(activeEngine.isRunning)")

        activeEngine.disconnectNodeOutput(activeEngine.inputNode)
        activeEngine.disconnectNodeInput(activeEngine.mainMixerNode)
        activeEngine.reset()

        engine = nil
        dspProcessor = nil
        webSocketAudioServer = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    func updateBypass(_ isBypassed: Bool, pitchShiftCents: Double) {
        dspProcessor?.update(pitchShiftCents: pitchShiftCents, bypassed: isBypassed)
        if isRunning {
            statusMessage = isBypassed ? "Running in bypass" : "Processing at \(pitchShiftCents) cents"
        }
    }

    func updatePitchShift(_ cents: Double, bypassed: Bool) {
        dspProcessor?.update(pitchShiftCents: cents, bypassed: bypassed)
        if isRunning && !bypassed {
            statusMessage = "Processing at \(cents) cents"
        }
    }

    private func deviceDescription(_ deviceID: AudioDeviceID?, in devices: [AudioDevice]) -> String {
        guard let deviceID else {
            return "System Default"
        }

        let name = devices.first { $0.id == deviceID }?.displayName ?? "Device \(deviceID)"
        return "\(name) [\(deviceID)]"
    }

    private func authorizationStatusLogName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        @unknown default:
            return "unknown"
        }
    }

    private func engineIdentity(_ engine: AVAudioEngine) -> String {
        String(describing: ObjectIdentifier(engine))
    }
}

extension AudioEngineManager {
    private func startEngine(
        pitchShiftCents: Double,
        bypassed: Bool,
        externalHeadphonesID: AudioDeviceID
    ) async throws {
        print("432 Resonance diagnostic: before creating AVAudioEngine.")
        let newEngine = AVAudioEngine()
        print("432 Resonance diagnostic: after creating AVAudioEngine.")
        engine = newEngine
        print("432 Resonance lifecycle: active engine assigned \(engineIdentity(newEngine)).")

        print("432 Resonance diagnostic: before creating DSPProcessor.")
        let dsp = DSPProcessor()
        print("432 Resonance diagnostic: after creating DSPProcessor.")
        dspProcessor = dsp

        print("432 Resonance diagnostic: before creating inputMixer.")
        let inputMixer = AVAudioMixerNode()
        print("432 Resonance diagnostic: after creating inputMixer.")
        inputMixer.outputVolume = 2.0
        print("432 Resonance diagnostic: inputMixer.outputVolume=\(inputMixer.outputVolume)")

        print("432 Resonance diagnostic: before instantiating ResonanceAudioUnit.")
        let resonanceAudioUnit = try await ResonanceAudioUnitRegistry.instantiate()
        print("432 Resonance diagnostic: after instantiating ResonanceAudioUnit.")
        guard let resonanceImplementation =
            resonanceAudioUnit.auAudioUnit as? ResonanceAudioUnit else {
            throw AudioEngineError.startupFailure(
                "The instantiated Audio Unit is not ResonanceAudioUnit."
            )
        }
        resonanceImplementation.setPitchCents(pitchShiftCents)

        var audioServer: WebSocketAudioServer?

        print("432 Resonance diagnostic: using ResonanceAudioUnit passthrough graph. requestedPitch=\(pitchShiftCents), bypass=\(bypassed)")

        print("432 Resonance diagnostic: before reading input node.")
        let inputNode = newEngine.inputNode
        print("432 Resonance diagnostic: after reading input node.")

        print("432 Resonance diagnostic: before reading main mixer node.")
        let mainMixer = newEngine.mainMixerNode
        print("432 Resonance diagnostic: after reading main mixer node.")
        mainMixer.outputVolume = 1.0
        print("432 Resonance diagnostic: mainMixerNode.outputVolume=\(mainMixer.outputVolume)")

        print("432 Resonance diagnostic: before reading output node.")
        let outputNode = newEngine.outputNode
        print("432 Resonance diagnostic: after reading output node.")

        print("432 Resonance diagnostic: before reading inputNode.inputFormat(forBus: 0).")
        let inputBusFormat = inputNode.inputFormat(forBus: 0)
        print("432 Resonance diagnostic: after reading inputNode.inputFormat(forBus: 0). format=\(inputBusFormat)")

        print("432 Resonance diagnostic: before reading inputNode.outputFormat(forBus: 0).")
        let inputOutputFormat = inputNode.outputFormat(forBus: 0)
        print("432 Resonance diagnostic: after reading inputNode.outputFormat(forBus: 0). format=\(inputOutputFormat)")

        print("432 Resonance diagnostic: before reading mainMixerNode.outputFormat(forBus: 0).")
        let mainMixerOutputFormat = mainMixer.outputFormat(forBus: 0)
        print("432 Resonance diagnostic: after reading mainMixerNode.outputFormat(forBus: 0). format=\(mainMixerOutputFormat)")

        print("432 Resonance diagnostic: before reading outputNode.outputFormat(forBus: 0).")
        let outputNodeOutputFormat = outputNode.outputFormat(forBus: 0)
        print("432 Resonance diagnostic: after reading outputNode.outputFormat(forBus: 0). format=\(outputNodeOutputFormat)")
        print("432 Resonance diagnostic: engine output route is current macOS default output; no explicit outputNode connection is made.")

        guard inputOutputFormat.channelCount > 0, inputOutputFormat.sampleRate > 0 else {
            throw AudioEngineError.startupFailure("The selected input device did not provide a valid audio format.")
        }

        print("432 Resonance diagnostic: before attaching inputMixer.")
        newEngine.attach(inputMixer)
        print("432 Resonance diagnostic: after attaching inputMixer.")

        print("432 Resonance diagnostic: before attaching ResonanceAudioUnit.")
        newEngine.attach(resonanceAudioUnit)
        print("432 Resonance diagnostic: after attaching ResonanceAudioUnit.")

        // Live audio pipeline:
        // selected default input -> input mixer -> ResonanceAudioUnit -> main mixer -> selected default output.
        print("432 Resonance diagnostic: before graph connection inputNode output format=\(inputNode.outputFormat(forBus: 0))")
        print("432 Resonance diagnostic: before graph connection inputMixer output format=\(inputMixer.outputFormat(forBus: 0))")
        print("432 Resonance diagnostic: before graph connection mainMixer input format=\(mainMixer.inputFormat(forBus: 0))")
        print("432 Resonance diagnostic: before graph connection ResonanceAudioUnit input format=\(resonanceAudioUnit.inputFormat(forBus: 0))")
        print("432 Resonance diagnostic: before graph connection ResonanceAudioUnit output format=\(resonanceAudioUnit.outputFormat(forBus: 0))")

        print("432 Resonance diagnostic: before connecting inputNode to inputMixer with inputNode.outputFormat(forBus: 0).")
        newEngine.connect(inputNode, to: inputMixer, format: inputOutputFormat)
        print("432 Resonance diagnostic: after connecting inputNode to inputMixer with inputNode.outputFormat(forBus: 0).")

        let sharedProcessingFormat = inputMixer.outputFormat(forBus: 0)
        print("432 Resonance diagnostic: shared ResonanceAudioUnit processing format from inputMixer output=\(sharedProcessingFormat)")
        guard sharedProcessingFormat.channelCount > 0, sharedProcessingFormat.sampleRate > 0 else {
            throw AudioEngineError.startupFailure("The input mixer did not provide a valid processing format for ResonanceAudioUnit.")
        }

        print("432 Resonance diagnostic: before connecting inputMixer to ResonanceAudioUnit with shared processing format.")
        newEngine.connect(inputMixer, to: resonanceAudioUnit, format: sharedProcessingFormat)
        print("432 Resonance diagnostic: after connecting inputMixer to ResonanceAudioUnit with shared processing format.")

        print("432 Resonance diagnostic: after input connection ResonanceAudioUnit input format=\(resonanceAudioUnit.inputFormat(forBus: 0))")
        print("432 Resonance diagnostic: after input connection ResonanceAudioUnit output format=\(resonanceAudioUnit.outputFormat(forBus: 0))")

        print("432 Resonance diagnostic: before connecting ResonanceAudioUnit to mainMixer with shared processing format.")
        newEngine.connect(resonanceAudioUnit, to: mainMixer, format: sharedProcessingFormat)
        print("432 Resonance diagnostic: after connecting ResonanceAudioUnit to mainMixer with shared processing format.")

        print("432 Resonance diagnostic: after graph connection inputNode output format=\(inputNode.outputFormat(forBus: 0))")
        print("432 Resonance diagnostic: after graph connection inputMixer output format=\(inputMixer.outputFormat(forBus: 0))")
        print("432 Resonance diagnostic: after graph connection mainMixer input format=\(mainMixer.inputFormat(forBus: 0))")
        print("432 Resonance diagnostic: after graph connection ResonanceAudioUnit input format=\(resonanceAudioUnit.inputFormat(forBus: 0))")
        print("432 Resonance diagnostic: after graph connection ResonanceAudioUnit output format=\(resonanceAudioUnit.outputFormat(forBus: 0))")

        if DEBUG_STREAMING {
            print("432 Resonance diagnostic: before starting WebSocket server.")
            let server = WebSocketAudioServer()
            try server.start()
            print("432 Resonance diagnostic: after starting WebSocket server.")
            audioServer = server
        } else {
            print("432 Resonance DEBUG_STREAMING=false. WebSocket server and audio broadcasting are disabled.")
        }

        if DEBUG_AUDIO_TAP {
            print("432 Resonance diagnostic: before installing processed tap.")
            installProcessedAudioTap(on: dsp.timePitch, audioServer: audioServer)
            print("432 Resonance diagnostic: after installing processed tap.")
        } else {
            print("432 Resonance DEBUG_AUDIO_TAP=false. Processed audio tap, tap logging, and AVAudioPCMBuffer access are disabled.")
        }

        print("432 Resonance diagnostic: pre-start inputNode output format=\(inputNode.outputFormat(forBus: 0))")
        print("432 Resonance diagnostic: pre-start inputMixer input format=\(inputMixer.inputFormat(forBus: 0))")
        print("432 Resonance diagnostic: pre-start inputMixer output format=\(inputMixer.outputFormat(forBus: 0))")
        print("432 Resonance diagnostic: pre-start ResonanceAudioUnit input format=\(resonanceAudioUnit.inputFormat(forBus: 0))")
        print("432 Resonance diagnostic: pre-start ResonanceAudioUnit output format=\(resonanceAudioUnit.outputFormat(forBus: 0))")
        print("432 Resonance diagnostic: pre-start mainMixer input format=\(mainMixer.inputFormat(forBus: 0))")

        print("432 Resonance diagnostic: before preparing engine.")
        newEngine.prepare()
        print("432 Resonance diagnostic: after preparing engine.")

        do {
            print("432 Resonance diagnostic: before starting engine.")
            try newEngine.start()
            print("432 Resonance diagnostic: after starting engine.")
            print("432 Resonance lifecycle: engine \(engineIdentity(newEngine)) isRunning after start=\(newEngine.isRunning)")
            print("432 Resonance engine started.")

            guard let (processedRingBuffer, processedSampleRate, channelCount) =
                resonanceImplementation.processedRingAccess() else {
                throw AudioEngineError.startupFailure(
                    "The processed-audio ring buffer is unavailable."
                )
            }

            let outputSampleRate = try HALOutputManager.outputSampleRate(
                deviceID: externalHeadphonesID
            )
            let converter = FixedRateAudioConverter()
            do {
                try converter.configure(
                    withSourceRing: processedRingBuffer,
                    sourceSampleRate: processedSampleRate,
                    outputSampleRate: outputSampleRate,
                    channelCount: UInt(channelCount)
                )
            } catch {
                throw AudioEngineError.deviceProblem(
                    "Could not configure fixed sample-rate conversion: " +
                    error.localizedDescription
                )
            }
            guard let convertedRingBuffer = converter.outputRingBuffer else {
                throw AudioEngineError.startupFailure(
                    "The converted-audio ring buffer is unavailable."
                )
            }
            fixedRateConverter = converter
            converter.start()

            let primeFrames = Int(ceil(outputSampleRate * 0.06))
            let primeDeadline = ContinuousClock.now + .seconds(2)
            while convertedRingBuffer.availableFrames < primeFrames {
                guard ContinuousClock.now < primeDeadline else {
                    throw AudioEngineError.startupFailure(
                        "Converted audio did not reach the 60 ms startup level."
                    )
                }
                try await Task.sleep(for: .milliseconds(5))
            }

            let testHALOutputManager = HALOutputManager()
            do {
                try testHALOutputManager.configure(
                    deviceID: externalHeadphonesID,
                    ringBuffer: convertedRingBuffer,
                    processedSampleRate: outputSampleRate
                )
                halOutputManager = testHALOutputManager
                try testHALOutputManager.start()
            } catch {
                throw AudioEngineError.deviceProblem(
                    "Could not start processed audio on External Headphones: " +
                    error.localizedDescription
                )
            }
            Task { @MainActor [weak self, weak resonanceImplementation, weak testHALOutputManager, weak converter] in
                try? await Task.sleep(for: .seconds(1))
                guard let self,
                      let resonanceImplementation,
                      let testHALOutputManager,
                      let converter,
                      self.halOutputManager === testHALOutputManager else {
                    return
                }
                let snapshot = resonanceImplementation.processedRingSnapshot()
                let convertedRing = converter.outputRingBuffer
                self.statusMessage =
                    "sourceRingAvailableFrames=\(snapshot.availableFrames)\n" +
                    "convertedRingAvailableFrames=\(convertedRing?.availableFrames ?? 0)\n" +
                    "sourceRingOverflowCount=\(snapshot.overflowCount)\n" +
                    "convertedRingOverflowCount=\(convertedRing?.overflowCount ?? 0)\n" +
                    "halUnderflowCount=\(testHALOutputManager.underflowCount)\n" +
                    "sourceSampleRate=\(converter.sourceSampleRate)\n" +
                    "outputSampleRate=\(converter.outputSampleRate)\n" +
                    "sourcePeak=\(converter.sourcePeak)\n" +
                    "convertedPeak=\(converter.convertedPeak)\n" +
                    "halOutputPeak=\(testHALOutputManager.outputPeak)\n" +
                    "converterProducedFrames=\(converter.converterProducedFrames)\n" +
                    "converterRequestedFrames=\(converter.converterRequestedFrames)"
            }
        } catch let error as AudioEngineError {
            audioServer?.stop()
            throw error
        } catch {
            let nsError = error as NSError
            print("432 Resonance engine start NSError domain=\(nsError.domain), code=\(nsError.code), userInfo=\(nsError.userInfo)")
            audioServer?.stop()
            throw AudioEngineError.startupFailure(error.localizedDescription)
        }

        webSocketAudioServer = audioServer
    }

    private func installProcessedAudioTap(on timePitchNode: AVAudioUnitTimePitch, audioServer: WebSocketAudioServer?) {
        var tapLogCount = 0
        let logQueue = DispatchQueue(label: "com.local.resonance432.processed-audio-tap-log")

        // This tap is installed on the output bus of AVAudioUnitTimePitch.
        // That point is downstream of pitch shifting, so buffers seen here are processed audio.
        timePitchNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            tapLogCount += 1

            let format = buffer.format
            let frameCount = buffer.frameLength
            let sampleRate = format.sampleRate
            let channelCount = format.channelCount
            let isBypassed = timePitchNode.bypass
            let messageNumber = tapLogCount

            if let audioServer {
                let pcmData = Self.interleavedFloat32PCMData(from: buffer)
                audioServer.broadcastPCMChunk(pcmData, sampleRate: sampleRate, channelCount: channelCount)
            }

            // Log the first few buffers, then every 50th buffer, to prove activity without flooding the console.
            guard tapLogCount <= 5 || tapLogCount.isMultiple(of: 50) else {
                return
            }

            logQueue.async {
                print(
                    "432 Resonance processed tap #\(messageNumber): " +
                    "source=AVAudioUnitTimePitch output, " +
                    "processedStage=true, " +
                    "format=\(format), " +
                    "frames=\(frameCount), " +
                    "sampleRate=\(sampleRate), " +
                    "channels=\(channelCount), " +
                    "bypass=\(isBypassed)"
                )
            }
        }

        print("432 Resonance processed tap installed on AVAudioUnitTimePitch output bus after pitch shift stage.")
    }

    private static func interleavedFloat32PCMData(from buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return Data()
        }

        if let floatChannelData = buffer.floatChannelData {
            var interleavedSamples = [Float]()
            interleavedSamples.reserveCapacity(frameCount * channelCount)

            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    interleavedSamples.append(floatChannelData[channelIndex][frameIndex])
                }
            }

            return interleavedSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        }

        let audioBufferList = buffer.audioBufferList.pointee
        guard audioBufferList.mNumberBuffers > 0,
              let dataPointer = audioBufferList.mBuffers.mData else {
            return Data()
        }

        return Data(bytes: dataPointer, count: Int(audioBufferList.mBuffers.mDataByteSize))
    }

    private func present(_ error: AudioEngineError) {
        isRunning = false
        statusMessage = "Not running"
        errorMessage = error.localizedDescription
    }
}
