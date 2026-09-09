import AudioToolbox
import CoreAudio
import Foundation

typealias AudioDeviceID = AudioObjectID

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let transportType: UInt32

    var displayName: String {
        name.isEmpty ? "Device \(id)" : name
    }

    var isBuiltInOutput: Bool {
        hasOutput && transportType == kAudioDeviceTransportTypeBuiltIn
    }
}

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var hasBlackHoleInput = false
    @Published private(set) var deviceListRevision = 0

    private var deviceListListener: AudioObjectPropertyListenerBlock?

    init() {
        installDeviceListListener()
    }

    deinit {
        guard let deviceListListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            deviceListListener
        )
    }

    func refreshDevices() {
        print("432 Resonance CoreAudio diagnostic: before refreshDevices.")
        let devices = Self.enumerateAudioDevices()
        inputDevices = devices.filter(\.hasInput).sorted { $0.displayName < $1.displayName }
        outputDevices = devices.filter(\.hasOutput).sorted { $0.displayName < $1.displayName }
        hasBlackHoleInput = blackHoleInputDevice != nil
        print("432 Resonance CoreAudio diagnostic: after refreshDevices. inputs=\(inputDevices.count), outputs=\(outputDevices.count), hasBlackHole=\(hasBlackHoleInput)")
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        print("432 Resonance CoreAudio diagnostic: before defaultInputDeviceID.")
        let deviceID = Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
        print("432 Resonance CoreAudio diagnostic: after defaultInputDeviceID. deviceID=\(String(describing: deviceID))")
        return deviceID
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        print("432 Resonance CoreAudio diagnostic: before defaultOutputDeviceID.")
        let deviceID = Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
        print("432 Resonance CoreAudio diagnostic: after defaultOutputDeviceID. deviceID=\(String(describing: deviceID))")
        return deviceID
    }

    func resolvedOutputDeviceID(selectedDeviceID: AudioDeviceID?) -> AudioDeviceID? {
        if let selectedDeviceID,
           outputDevices.contains(where: { $0.id == selectedDeviceID }) {
            return selectedDeviceID
        }

        if let externalHeadphones = outputDevices.first(where: {
            $0.displayName.compare(
                "External Headphones",
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) {
            return externalHeadphones.id
        }

        if let builtInOutput = outputDevices.first(where: \.isBuiltInOutput) {
            return builtInOutput.id
        }

        return nil
    }

    var blackHoleInputDevice: AudioDevice? {
        inputDevices.first {
            $0.displayName.compare(
                "BlackHole 2ch",
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        } ?? inputDevices.first {
            $0.displayName.localizedCaseInsensitiveContains("BlackHole")
        }
    }

    var blackHoleInputName: String? {
        blackHoleInputDevice?.displayName
    }

    func isOutputDeviceAvailable(_ deviceID: AudioDeviceID?) -> Bool {
        guard let deviceID else { return false }
        return outputDevices.contains { $0.id == deviceID }
    }

    func resolvedOutputDeviceName(selectedDeviceID: AudioDeviceID?) -> String? {
        guard let deviceID = resolvedOutputDeviceID(
            selectedDeviceID: selectedDeviceID
        ) else {
            return nil
        }
        return outputDevices.first { $0.id == deviceID }?.displayName
    }

    func currentDefaultInputDeviceName() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return inputDevices.first { $0.id == deviceID }?.displayName
    }

    private static var deviceListPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func installDeviceListListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshDevices()
                self.deviceListRevision &+= 1
            }
        }
        var address = Self.deviceListPropertyAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        )
        if status == noErr {
            deviceListListener = listener
        } else {
            print("432 Resonance could not observe audio-device changes. OSStatus=\(status)")
        }
    }
}

extension DeviceManager {
    private static func enumerateAudioDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        print("432 Resonance CoreAudio diagnostic: before AudioObjectGetPropertyDataSize(kAudioHardwarePropertyDevices).")
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        print("432 Resonance CoreAudio diagnostic: after AudioObjectGetPropertyDataSize(kAudioHardwarePropertyDevices). status=\(sizeStatus), dataSize=\(dataSize)")
        guard sizeStatus == noErr else {
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)
        print("432 Resonance CoreAudio diagnostic: before AudioObjectGetPropertyData(kAudioHardwarePropertyDevices).")
        let dataStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)
        print("432 Resonance CoreAudio diagnostic: after AudioObjectGetPropertyData(kAudioHardwarePropertyDevices). status=\(dataStatus), deviceCount=\(deviceCount)")
        guard dataStatus == noErr else {
            return []
        }

        return deviceIDs.map { deviceID in
            AudioDevice(
                id: deviceID,
                name: deviceName(for: deviceID),
                hasInput: streamCount(for: deviceID, scope: kAudioDevicePropertyScopeInput) > 0,
                hasOutput: streamCount(for: deviceID, scope: kAudioDevicePropertyScopeOutput) > 0,
                transportType: transportType(for: deviceID)
            )
        }
    }

    private static func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &transportType
        )
        return status == noErr ? transportType : 0
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        print("432 Resonance CoreAudio diagnostic: before AudioObjectGetPropertyData(kAudioObjectPropertyName) for device \(deviceID).")
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        print("432 Resonance CoreAudio diagnostic: after AudioObjectGetPropertyData(kAudioObjectPropertyName) for device \(deviceID). status=\(status), name=\(status == noErr ? (name as String) : "")")
        return status == noErr ? (name as String) : ""
    }

    private static func streamCount(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        print("432 Resonance CoreAudio diagnostic: before AudioObjectGetPropertyDataSize(kAudioDevicePropertyStreams) for device \(deviceID), scope=\(scope).")
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        print("432 Resonance CoreAudio diagnostic: after AudioObjectGetPropertyDataSize(kAudioDevicePropertyStreams) for device \(deviceID), scope=\(scope). status=\(status), dataSize=\(dataSize)")
        guard status == noErr else {
            return 0
        }
        return Int(dataSize) / MemoryLayout<AudioStreamID>.size
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        print("432 Resonance CoreAudio diagnostic: before AudioObjectGetPropertyData(default device selector \(selector)).")
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        print("432 Resonance CoreAudio diagnostic: after AudioObjectGetPropertyData(default device selector \(selector)). status=\(status), deviceID=\(deviceID)")
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }
}
