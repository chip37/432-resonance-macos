import AudioToolbox
import CoreAudio
import Foundation

typealias AudioDeviceID = AudioObjectID

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let hasInput: Bool
    let hasOutput: Bool

    var displayName: String {
        name.isEmpty ? "Device \(id)" : name
    }
}

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var hasBlackHoleInput = false

    func refreshDevices() {
        print("432 Resonance CoreAudio diagnostic: before refreshDevices.")
        let devices = Self.enumerateAudioDevices()
        inputDevices = devices.filter(\.hasInput).sorted { $0.displayName < $1.displayName }
        outputDevices = devices.filter(\.hasOutput).sorted { $0.displayName < $1.displayName }
        hasBlackHoleInput = inputDevices.contains { $0.displayName.localizedCaseInsensitiveContains("BlackHole") }
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
                hasOutput: streamCount(for: deviceID, scope: kAudioDevicePropertyScopeOutput) > 0
            )
        }
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
