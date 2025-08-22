import SwiftUI
import AudioToolbox

struct VerticalPianoKeyboard: View {
    let activeNotes: Set<Int>
    let onNoteTap: (Int) -> Void
    
    @State private var pressedKeys: Set<Int> = []
    
    private let whiteKeyHeight: CGFloat = 12
    private let blackKeyHeight: CGFloat = 8
    private let whiteKeyWidth: CGFloat = 60
    private let blackKeyWidth: CGFloat = 40
    
    // Piano key range (A0 to C8) - but limit to visible keys
    private let minNote = 21
    private let maxNote = 108
    private let totalKeys = 88
    
    var body: some View {
        HStack(spacing: 0) {
            // Piano Keys (Vertical)
            ZStack {
                // White keys background
                VStack(spacing: 0) {
                    ForEach(0..<totalKeys, id: \.self) { i in
                        let midiNote = minNote + i
                        let noteInOctave = (midiNote % 12)
                        let isWhiteKey = ![1, 3, 6, 8, 10].contains(noteInOctave)
                        
                        if isWhiteKey {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                                .overlay(
                                    Rectangle()
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                                )
                                .onTapGesture {
                                    onNoteTap(midiNote)
                                    animateKeyPress(midiNote)
                                }
                        }
                    }
                }
                
                // Black keys overlay
                VStack(spacing: 0) {
                    ForEach(0..<totalKeys, id: \.self) { i in
                        let midiNote = minNote + i
                        let noteInOctave = (midiNote % 12)
                        let isBlackKey = [1, 3, 6, 8, 10].contains(noteInOctave)
                        
                        if isBlackKey {
                            Rectangle()
                                .fill(Color.black)
                                .frame(width: blackKeyWidth, height: blackKeyHeight)
                                .offset(y: whiteKeyHeight / 2 - blackKeyHeight / 2)
                                .onTapGesture {
                                    onNoteTap(midiNote)
                                    animateKeyPress(midiNote)
                                }
                        } else {
                            Spacer()
                                .frame(height: whiteKeyHeight)
                        }
                    }
                }
                
                // Active note highlights
                ForEach(Array(activeNotes), id: \.self) { midiNote in
                    let noteInOctave = (midiNote % 12)
                    let isBlackKey = [1, 3, 6, 8, 10].contains(noteInOctave)
                    let keyIndex = midiNote - minNote
                    let yOffset = CGFloat(keyIndex) * whiteKeyHeight
                    
                    if isBlackKey {
                        // Black key highlight
                        Rectangle()
                            .fill(Color.blue.opacity(0.8))
                            .frame(width: blackKeyWidth, height: blackKeyHeight)
                            .offset(y: yOffset + whiteKeyHeight / 2 - blackKeyHeight / 2)
                    } else {
                        // White key highlight
                        Rectangle()
                            .fill(Color.blue.opacity(0.6))
                            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                            .offset(y: yOffset)
                    }
                }
                
                // Pressed key highlights
                ForEach(Array(pressedKeys), id: \.self) { midiNote in
                    let noteInOctave = (midiNote % 12)
                    let isBlackKey = [1, 3, 6, 8, 10].contains(noteInOctave)
                    let keyIndex = midiNote - minNote
                    let yOffset = CGFloat(keyIndex) * whiteKeyHeight
                    
                    if isBlackKey {
                        Rectangle()
                            .fill(Color.green.opacity(0.9))
                            .frame(width: blackKeyWidth, height: blackKeyHeight)
                            .offset(y: yOffset + whiteKeyHeight / 2 - blackKeyHeight / 2)
                    } else {
                        Rectangle()
                            .fill(Color.green.opacity(0.7))
                            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                            .offset(y: yOffset)
                    }
                }
            }
            .frame(width: whiteKeyWidth, height: CGFloat(totalKeys) * whiteKeyHeight)
            .clipped()
            
            // Note labels (vertical)
            VStack(spacing: 0) {
                ForEach(0..<totalKeys, id: \.self) { i in
                    let midiNote = minNote + i
                    let noteInOctave = (midiNote % 12)
                    let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
                    let noteName = noteNames[noteInOctave]
                    let octave = (midiNote / 12) - 1
                    
                    VStack(spacing: 2) {
                        Text(noteName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        if noteName == "C" {
                            Text("\(octave)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    .frame(height: whiteKeyHeight)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 30)
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
    
    private func animateKeyPress(_ midiNote: Int) {
        pressedKeys.insert(midiNote)
        
        // Haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
        
        // Remove from pressed keys after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pressedKeys.remove(midiNote)
        }
    }
}

#Preview {
    VerticalPianoKeyboard(
        activeNotes: [60, 64, 67],
        onNoteTap: { _ in }
    )
    .padding()
}
