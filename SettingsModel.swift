import Foundation

@MainActor
final class SettingsModel: ObservableObject {
    @Published var selectedInputDeviceID: AudioDeviceID?
    @Published var selectedOutputDeviceID: AudioDeviceID?
    @Published var pitchShiftCents: Double = -31.77
    @Published var isBypassed: Bool = false
}
