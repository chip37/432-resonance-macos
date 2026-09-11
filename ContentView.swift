import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var deviceManager: DeviceManager
    @EnvironmentObject private var audioEngineManager: AudioEngineManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            statusArea

            primaryButton
        }
        .padding(24)
        .onAppear {
            deviceManager.refreshDevices()
            selectOutputDefaultIfNeeded()
        }
        .onChange(of: deviceManager.deviceListRevision) { _, _ in
            Task {
                await audioEngineManager.handleDeviceListChange(
                    settings: settings,
                    deviceManager: deviceManager
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("432 Resonance")
                .font(.title.bold())
            Text("System audio, retuned to 432 Hz")
                .foregroundStyle(.secondary)
        }
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(readinessHeading)
                    .font(.headline)
            }

            LabeledContent("Input") {
                Text(inputStatus)
            }

            LabeledContent("Output") {
                if audioEngineManager.isRunning {
                    Text(displayedOutputName)
                } else {
                    Picker("Output", selection: outputSelection) {
                        Text("Automatic").tag(AudioDeviceID?.none)
                        ForEach(deviceManager.outputDevices) { device in
                            Text(device.displayName).tag(AudioDeviceID?.some(device.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
            }

            LabeledContent("Remote Streaming") {
                Text(streamingStatus)
            }

            if let visibleError {
                Divider()
                Text(visibleError)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var canResolveOutput: Bool {
        deviceManager.resolvedOutputDeviceID(
            selectedDeviceID: settings.selectedOutputDeviceID
        ) != nil
    }

    private var isReady: Bool {
        blackHoleIsDefaultInput &&
            canResolveOutput &&
            audioEngineManager.errorMessage.isEmpty
    }

    private var blackHoleIsDefaultInput: Bool {
        guard let blackHoleID = deviceManager.blackHoleInputDevice?.id,
              let defaultInputID = deviceManager.defaultInputDeviceID() else {
            return false
        }
        return blackHoleID == defaultInputID
    }

    private var readinessHeading: String {
        if audioEngineManager.isRunning { return "Processing at 432 Hz" }
        return isReady ? "Ready" : "Not Ready"
    }

    private var statusColor: Color {
        if audioEngineManager.isRunning { return .green }
        return isReady ? .blue : .gray
    }

    private var inputStatus: String {
        if blackHoleIsDefaultInput {
            return deviceManager.blackHoleInputName ?? "BlackHole 2ch"
        }
        return deviceManager.hasBlackHoleInput
            ? "BlackHole 2ch not selected"
            : "BlackHole 2ch not installed"
    }

    private var displayedOutputName: String {
        if !audioEngineManager.activeOutputName.isEmpty {
            return audioEngineManager.activeOutputName
        }
        return deviceManager.resolvedOutputDeviceName(
            selectedDeviceID: settings.selectedOutputDeviceID
        ) ?? "Unavailable"
    }

    private var streamingStatus: String {
        if !isReady && !audioEngineManager.isRunning { return "Unavailable" }
        return audioEngineManager.streamingActive ? "Active" : "Inactive"
    }

    private var visibleError: String? {
        if !audioEngineManager.errorMessage.isEmpty {
            return audioEngineManager.errorMessage
        }
        if !deviceManager.hasBlackHoleInput {
            return "BlackHole 2ch was not found. Install BlackHole 2ch before starting."
        }
        if !blackHoleIsDefaultInput {
            return "BlackHole 2ch must be selected as your Mac's Sound Input.\nOpen System Settings → Sound → Input → BlackHole 2ch."
        }
        if !canResolveOutput {
            return "No audio output is available. Connect speakers or headphones."
        }
        return nil
    }

    private var outputSelection: Binding<AudioDeviceID?> {
        Binding(
            get: { settings.selectedOutputDeviceID },
            set: { settings.selectedOutputDeviceID = $0 }
        )
    }

    @ViewBuilder
    private var primaryButton: some View {
        if audioEngineManager.isRunning {
            Button("Stop Processing") {
                audioEngineManager.stop()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        } else {
            Button("Start Processing") {
                Task {
                    await audioEngineManager.start(
                        settings: settings,
                        deviceManager: deviceManager
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!isReady)
            .frame(maxWidth: .infinity)
        }
    }

    private func selectOutputDefaultIfNeeded() {
        if settings.selectedOutputDeviceID == nil {
            settings.selectedOutputDeviceID = deviceManager.defaultOutputDeviceID()
        }
    }
}
