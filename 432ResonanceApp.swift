import SwiftUI

@main
struct Resonance432App: App {
    @StateObject private var settings = SettingsModel()
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var audioEngineManager = AudioEngineManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(deviceManager)
                .environmentObject(audioEngineManager)
                .frame(minWidth: 560, minHeight: 420)
        }
        .windowStyle(.titleBar)
    }
}
