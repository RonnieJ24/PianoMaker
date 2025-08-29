import SwiftUI
import AudioToolbox

struct LivePianoKeyboard: View {
    let currentChord: Chord?
    let activeNotes: [Int]
    let onNoteTap: (Int) -> Void
    
    @State private var pressedKeys: Set<Int> = []
    
    private let whiteKeyWidth: CGFloat = 40
    private let whiteKeyHeight: CGFloat = 120
    private let blackKeyWidth: CGFloat = 24
    private let blackKeyHeight: CGFloat = 80
    
    var body: some View {
        VStack(spacing: 0) {
            // Chord Display
            if let chord = currentChord {
                VStack(spacing: 4) {
                    Text(chord.displayName)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text(chord.fullName)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            
            // Piano Keyboard
            ZStack {
                // White keys background
                HStack(spacing: 0) {
                    ForEach(0..<52, id: \.self) { i in
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                            .overlay(
                                Rectangle()
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .onTapGesture {
                                let midiNote = 21 + i // A0 to C8
                                onNoteTap(midiNote)
                                animateKeyPress(midiNote)
                            }
                    }
                }
                
                // Black keys overlay
                HStack(spacing: 0) {
                    ForEach(0..<51, id: \.self) { i in
                        let midiNote = 21 + i
                        let noteInOctave = (midiNote % 12)
                        let isBlackKey = [1, 3, 6, 8, 10].contains(noteInOctave)
                        
                        if isBlackKey {
                            Rectangle()
                                .fill(Color.black)
                                .frame(width: blackKeyWidth, height: blackKeyHeight)
                                .offset(x: whiteKeyWidth / 2 - blackKeyWidth / 2)
                                .onTapGesture {
                                    onNoteTap(midiNote)
                                    animateKeyPress(midiNote)
                                }
                        }
                        
                        Spacer()
                            .frame(width: whiteKeyWidth)
                    }
                }
                
                // Active note highlights
                ForEach(activeNotes, id: \.self) { midiNote in
                    let noteInOctave = (midiNote % 12)
                    let isBlackKey = [1, 3, 6, 8, 10].contains(noteInOctave)
                    let keyIndex = midiNote - 21
                    let xOffset = CGFloat(keyIndex) * whiteKeyWidth
                    
                    if isBlackKey {
                        // Black key highlight
                        Rectangle()
                            .fill(Color.blue.opacity(0.8))
                            .frame(width: blackKeyWidth, height: blackKeyHeight)
                            .offset(x: xOffset + whiteKeyWidth / 2 - blackKeyWidth / 2)
                    } else {
                        // White key highlight
                        Rectangle()
                            .fill(Color.blue.opacity(0.6))
                            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                            .offset(x: xOffset)
                    }
                }
                
                // Pressed key highlights
                ForEach(Array(pressedKeys), id: \.self) { midiNote in
                    let noteInOctave = (midiNote % 12)
                    let isBlackKey = [1, 3, 6, 8, 10].contains(noteInOctave)
                    let keyIndex = midiNote - 21
                    let xOffset = CGFloat(keyIndex) * whiteKeyWidth
                    
                    if isBlackKey {
                        Rectangle()
                            .fill(Color.green.opacity(0.9))
                            .frame(width: blackKeyWidth, height: blackKeyHeight)
                            .offset(x: xOffset + whiteKeyWidth / 2 - blackKeyWidth / 2)
                    } else {
                        Rectangle()
                            .fill(Color.green.opacity(0.7))
                            .frame(width: whiteKeyWidth, height: whiteKeyHeight)
                            .offset(x: xOffset)
                    }
                }
            }
            .frame(height: whiteKeyHeight)
            .clipped()
            
            // Note labels
            HStack(spacing: 0) {
                ForEach(0..<52, id: \.self) { i in
                    let midiNote = 21 + i
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
                    .frame(width: whiteKeyWidth)
                }
            }
            .padding(.top, 8)
        }
        .background(Color(.systemBackground))
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
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
    LivePianoKeyboard(
        currentChord: Chord(
            root: "C",
            quality: "maj",
            notes: [60, 64, 67],
            startTime: 0,
            endTime: 1
        ),
        activeNotes: [60, 64, 67],
        onNoteTap: { _ in }
    )
    .padding()
}

