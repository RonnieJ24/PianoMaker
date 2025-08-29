import Foundation

enum TranscriptionStatus: String, Codable {
    case processing
    case done
    case error
}

struct TranscriptionResponse: Codable {
    let status: TranscriptionStatus
    let midi_url: URL?
    let duration_sec: Double?
    let notes: Int?
    let job_id: String?
    let error: String?

    var midiURL: URL? { midi_url }
    var jobId: String? { job_id }
}

struct CompletedTranscription: Codable, Identifiable {
    let id: UUID
    let sourceFileName: String
    let date: Date
    let midiLocalURL: URL
    let durationSec: Double?
    let notes: Int?
}



