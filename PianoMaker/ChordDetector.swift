import Foundation

class ChordDetector: ObservableObject {
    @Published var currentChord: Chord?
    private var noteData: [PianoNote] = []
    
    func reset() {
        noteData.removeAll()
        currentChord = nil
    }
    
    func addNote(_ note: PianoNote) {
        noteData.append(note)
    }
    
    func analyzeMIDIAtTime(_ currentTime: Double) {
        // Get active notes at current time
        let activeNotes = noteData.filter { note in
            note.start <= currentTime && note.end >= currentTime
        }
        
        if activeNotes.count >= 3 {
            // Simple chord detection based on note intervals
            let sortedNotes = activeNotes.sorted { $0.pitch < $1.pitch }
            let rootNote = sortedNotes[0]
            
            // Basic chord quality detection
            let quality = detectChordQuality(from: sortedNotes)
            
            let chord = Chord(
                root: rootNote.noteName.replacingOccurrences(of: "[0-9]", with: "", options: .regularExpression),
                quality: quality,
                notes: sortedNotes.map { $0.pitch },
                startTime: currentTime,
                endTime: currentTime + 1.0
            )
            
            currentChord = chord
        } else {
            currentChord = nil
        }
    }
    
    private func detectChordQuality(from notes: [PianoNote]) -> String {
        guard notes.count >= 3 else { return "maj" }
        
        let pitches = notes.map { $0.pitch }
        let intervals = zip(pitches, pitches.dropFirst()).map { $1 - $0 }
        
        // Basic chord detection
        if intervals.count >= 2 {
            if intervals[0] == 3 && intervals[1] == 4 {
                return "maj" // Major triad
            } else if intervals[0] == 3 && intervals[1] == 3 {
                return "min" // Minor triad
            } else if intervals[0] == 4 && intervals[1] == 3 {
                return "sus2" // Suspended 2nd
            } else if intervals[0] == 3 && intervals[1] == 4 && intervals.count >= 3 && intervals[2] == 3 {
                return "7" // Dominant 7th
            }
        }
        
        return "maj" // Default to major
    }
}
