import Foundation

struct PianoNote: Identifiable, Codable, Equatable {
    let id = UUID()
    let start: Double
    let duration: Double
    let pitch: Int
    
    var end: Double {
        start + duration
    }
    
    var midiNote: Int {
        pitch
    }
    
    var frequency: Double {
        440.0 * pow(2.0, (Double(pitch) - 69.0) / 12.0)
    }
    
    var noteName: String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (pitch / 12) - 1
        let noteIndex = pitch % 12
        return "\(noteNames[noteIndex])\(octave)"
    }
    
    init(start: Double, duration: Double, pitch: Int) {
        self.start = start
        self.duration = duration
        self.pitch = pitch
    }
}
