import AVFoundation

final class DSPProcessor {
    let timePitch = AVAudioUnitTimePitch()

    init() {
        timePitch.rate = 1.0
        timePitch.overlap = 8.0
    }

    func update(pitchShiftCents: Double, bypassed: Bool) {
        timePitch.pitch = Float(pitchShiftCents)
        timePitch.rate = 1.0
        timePitch.bypass = bypassed
    }
}
