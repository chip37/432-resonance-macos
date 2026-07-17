import AVFoundation

enum ResonanceAudioUnitRegistry {
    private static var isRegistered = false

    static func instantiate() async throws -> AVAudioUnit {
        registerIfNeeded()

        return try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(
                with: ResonanceAudioUnit.componentDescription,
                options: []
            ) { audioUnit, error in
                if let audioUnit {
                    continuation.resume(returning: audioUnit)
                } else {
                    continuation.resume(throwing: error ?? AudioEngineError.startupFailure("ResonanceAudioUnit instantiation returned no Audio Unit."))
                }
            }
        }
    }

    private static func registerIfNeeded() {
        guard !isRegistered else {
            return
        }

        AUAudioUnit.registerSubclass(
            ResonanceAudioUnit.self,
            as: ResonanceAudioUnit.componentDescription,
            name: "432 Resonance: ResonanceAudioUnit",
            version: 1
        )
        isRegistered = true
        print("432 Resonance Audio Unit registered: ResonanceAudioUnit")
    }
}
