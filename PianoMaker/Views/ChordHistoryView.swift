import SwiftUI

struct ChordHistoryView: View {
    let chordHistory: [Chord]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundColor(.blue)
                
                Text("Chord Progression")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Text("\(chordHistory.count) chords")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.1))
                    )
            }
            
            if chordHistory.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.6))
                    
                    Text("No chords detected yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text("Start playing to see chord analysis")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(chordHistory.enumerated()), id: \.element.id) { index, chord in
                            ChordCard(chord: chord, index: index)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
    }
}

struct ChordCard: View {
    let chord: Chord
    let index: Int
    
    private var gradientColors: [Color] {
        switch chord.quality {
        case "maj", "maj7":
            return [Color.blue.opacity(0.8), Color.blue.opacity(0.6)]
        case "min", "min7":
            return [Color.purple.opacity(0.8), Color.purple.opacity(0.6)]
        case "7":
            return [Color.orange.opacity(0.8), Color.orange.opacity(0.6)]
        case "dim":
            return [Color.red.opacity(0.8), Color.red.opacity(0.6)]
        case "aug":
            return [Color.yellow.opacity(0.8), Color.yellow.opacity(0.6)]
        case "sus2", "sus4":
            return [Color.green.opacity(0.8), Color.green.opacity(0.6)]
        default:
            return [Color.gray.opacity(0.8), Color.gray.opacity(0.6)]
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Chord symbol
            Text(chord.displayName)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 60, height: 60)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: gradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
            
            // Chord name
            Text(chord.fullName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            
            // Position indicator
            Text("#\(index + 1)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.1))
                )
        }
        .frame(width: 80)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: gradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                )
        )
    }
}

#Preview {
    ChordHistoryView(chordHistory: [
        Chord(root: "C", quality: "maj", notes: [60, 64, 67], startTime: 0, endTime: 1),
        Chord(root: "G", quality: "7", notes: [67, 71, 74, 77], startTime: 1, endTime: 2),
        Chord(root: "Am", quality: "min", notes: [69, 72, 76], startTime: 2, endTime: 3),
        Chord(root: "F", quality: "maj", notes: [65, 69, 72], startTime: 3, endTime: 4)
    ])
    .padding()
}

