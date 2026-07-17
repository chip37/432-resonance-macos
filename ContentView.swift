import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var deviceManager: DeviceManager
    @EnvironmentObject private var audioEngineManager: AudioEngineManager

    @State private var pitchText = "-31.77"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Form {
                Picker("Input Device", selection: inputSelection) {
                    Text("System Default").tag(AudioDeviceID?.none)
                    ForEach(deviceManager.inputDevices) { device in
                        Text(device.displayName).tag(AudioDeviceID?.some(device.id))
                    }
                }

                Picker("Output Device", selection: outputSelection) {
                    Text("System Default").tag(AudioDeviceID?.none)
                    ForEach(deviceManager.outputDevices) { device in
                        Text(device.displayName).tag(AudioDeviceID?.some(device.id))
                    }
                }

                TextField("Pitch Shift (cents)", text: $pitchText)
                    .onSubmit(applyPitchText)

                Toggle("Bypass", isOn: $settings.isBypassed)
                    .onChange(of: settings.isBypassed) { _, newValue in
                        audioEngineManager.updateBypass(newValue, pitchShiftCents: settings.pitchShiftCents)
                    }
            }
            .formStyle(.grouped)

            HStack(spacing: 12) {
                Button("Start Processing") {
                    applyPitchText()
                    Task {
                        await audioEngineManager.start(settings: settings, deviceManager: deviceManager)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(audioEngineManager.isRunning)

                Button("Stop Processing") {
                    audioEngineManager.stop()
                }
                .disabled(!audioEngineManager.isRunning)

                Button("Refresh Devices") {
                    deviceManager.refreshDevices()
                    selectDefaultsIfNeeded()
                }
            }

            statusArea

            Text("Note: device selection is implemented by asking CoreAudio to switch the macOS default input/output before starting. Dedicated per-engine output routing is future CoreAudio work.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .onAppear {
            deviceManager.refreshDevices()
            selectDefaultsIfNeeded()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("432 Resonance")
                .font(.title.bold())
            Text("Live input -> pitch shift -> output")
                .foregroundStyle(.secondary)
        }
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(audioEngineManager.isRunning ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(audioEngineManager.statusMessage)
                    .font(.headline)
            }

            if !audioEngineManager.errorMessage.isEmpty {
                Text(audioEngineManager.errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if !deviceManager.hasBlackHoleInput {
                Text("BlackHole 2ch was not detected. Select another input or install BlackHole for system-audio routing.")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var inputSelection: Binding<AudioDeviceID?> {
        Binding(
            get: { settings.selectedInputDeviceID },
            set: { settings.selectedInputDeviceID = $0 }
        )
    }

    private var outputSelection: Binding<AudioDeviceID?> {
        Binding(
            get: { settings.selectedOutputDeviceID },
            set: { settings.selectedOutputDeviceID = $0 }
        )
    }

    private func applyPitchText() {
        guard let value = Double(pitchText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            audioEngineManager.updatePitchShift(settings.pitchShiftCents, bypassed: settings.isBypassed)
            return
        }
        settings.pitchShiftCents = value
        audioEngineManager.updatePitchShift(value, bypassed: settings.isBypassed)
    }

    private func selectDefaultsIfNeeded() {
        if settings.selectedInputDeviceID == nil {
            settings.selectedInputDeviceID = deviceManager.defaultInputDeviceID()
        }
        if settings.selectedOutputDeviceID == nil {
            settings.selectedOutputDeviceID = deviceManager.defaultOutputDeviceID()
        }
    }
}
