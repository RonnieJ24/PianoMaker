import Foundation

struct Chord: Identifiable, Codable, Equatable {
    let id = UUID()
    let root: String
    let quality: String
    let notes: [Int]
    let startTime: Double
    let endTime: Double
    
    var displayName: String {
        "\(root)\(quality)"
    }
    
    var fullName: String {
        switch quality {
        case "maj":
            return "\(root) Major"
        case "min":
            return "\(root) Minor"
        case "7":
            return "\(root) Dominant 7th"
        case "maj7":
            return "\(root) Major 7th"
        case "min7":
            return "\(root) Minor 7th"
        case "dim":
            return "\(root) Diminished"
        case "aug":
            return "\(root) Augmented"
        case "sus2":
            return "\(root) Suspended 2nd"
        case "sus4":
            return "\(root) Suspended 4th"
        default:
            return "\(root) \(quality)"
        }
    }
    
    var duration: Double {
        endTime - startTime
    }
    
    init(root: String, quality: String, notes: [Int], startTime: Double, endTime: Double) {
        self.root = root
        self.quality = quality
        self.notes = notes
        self.startTime = startTime
        self.endTime = endTime
    }
}
