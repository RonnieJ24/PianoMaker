import SwiftUI

struct MIDIGridView: View {
    let midiNotes: [PianoNote]
    let currentTime: Double
    let duration: Double
    let activeNotes: Set<Int>
    
    private let gridWidth: CGFloat = 400
    private let gridHeight: CGFloat = 400 // More reasonable size
    private let minNote = 21
    private let maxNote = 108
    private let totalKeys = 88
    private let keyHeight: CGFloat = 24
    
    var body: some View {
        ZStack {
            // Grid background
            VStack(spacing: 0) {
                ForEach(0..<totalKeys, id: \.self) { i in
                    Rectangle()
                        .fill(i % 12 == 0 ? Color.gray.opacity(0.1) : Color.gray.opacity(0.05))
                        .frame(height: keyHeight)
                        .overlay(
                            Rectangle()
                                .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
                        )
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            
            // Time markers (vertical lines)
            HStack(spacing: 0) {
                ForEach(0..<Int(duration) + 1, id: \.self) { second in
                    Rectangle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 1, height: gridHeight)
                    
                    if second < Int(duration) {
                        Spacer()
                            .frame(width: gridWidth / duration - 1)
                    }
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            
            // MIDI notes
            ForEach(midiNotes, id: \.id) { note in
                let noteIndex = note.pitch - minNote
                let yPosition = CGFloat(noteIndex) * keyHeight
                let xPosition = (note.start / duration) * gridWidth
                let noteWidth = (note.duration / duration) * gridWidth
                
                Rectangle()
                    .fill(activeNotes.contains(note.pitch) ? Color.blue : Color.green.opacity(0.7))
                    .frame(width: max(noteWidth, 2), height: keyHeight - 1)
                    .position(x: xPosition + noteWidth/2, y: yPosition + keyHeight/2)
                    .overlay(
                        Rectangle()
                            .stroke(Color.white.opacity(0.8), lineWidth: 1)
                    )
            }
            
            // Playhead (current time indicator)
            let playheadX = (currentTime / duration) * gridWidth
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: gridHeight)
                .position(x: playheadX, y: gridHeight/2)
                .shadow(color: .red.opacity(0.8), radius: 2, x: 0, y: 0)
        }
        .frame(width: gridWidth, height: gridHeight)
        .background(Color(.systemBackground))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
    }
}

#Preview {
    MIDIGridView(
        midiNotes: [
            PianoNote(start: 0.0, duration: 1.0, pitch: 60),
            PianoNote(start: 1.0, duration: 1.0, pitch: 64),
            PianoNote(start: 2.0, duration: 1.0, pitch: 67)
        ],
        currentTime: 1.5,
        duration: 4.0,
        activeNotes: [64]
    )
    .padding()
}
