import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var selectedFileURL: URL?
    @Published var midiLocalURL: URL?
    @Published var isUploading: Bool = false
    @Published var errorMessage: String?
    @Published var useDemucs: Bool = false
    @Published var notesCount: Int?
    @Published var durationSec: Double?
    @Published var history: [CompletedTranscription] = []
    @Published var usePTI: Bool = false
    @Published var instrumentalURL: URL?
    @Published var vocalsURL: URL?
    @Published var isSeparating: Bool = false
    @Published var progressText: String? // shows simple loading state
    @Published var lastRenderedWav: URL?
    @Published var coverStyle: String = "block" // block, arpeggio, alberti
    @Published var profile: String = "balanced" // fast, balanced, accurate
    @Published var separationBackend: String? // displays backend used
    @Published var infoMessage: String?
    @Published var separatingElapsedSec: Int = 0
    @Published var separatingEstimateSec: Int?
    @Published var separatingProgress: Double = 0
    private var separatingTimer: Timer?
    private var currentTask: Task<Void, Never>?

    // Create a small, upload-friendly copy to reduce simulator timeouts
    private func makeUploadFriendlyCopy(from url: URL) async -> URL {
        // If already a small compressed format, reuse
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? NSNumber, size.intValue < 15_000_000 { // <15MB
                let ext = url.pathExtension.lowercased()
                if ["m4a","mp3","aac"].contains(ext) { return url }
            }
        } catch { }
        let asset = AVURLAsset(url: url)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return url
        }
        let out = FileManager.default.temporaryDirectory.appending(path: "upload_\(UUID().uuidString).m4a")
        exporter.outputURL = out
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { c.resume() }
        }
        if exporter.status == .completed { return out }
        return url
    }

    func setSelectedFile(_ url: URL) {
        selectedFileURL = url
        midiLocalURL = nil
        notesCount = nil
        durationSec = nil
        instrumentalURL = nil
        vocalsURL = nil
        separationBackend = nil
        progressText = nil
        currentTask?.cancel(); currentTask = nil
    }

    @MainActor
    func transcribeSelectedFile() async {
        guard let fileURL = selectedFileURL else { return }
        isUploading = true
        defer { isUploading = false }

        do {
            // Try streaming/async path first to avoid client timeouts on long songs
            var fields: [String:String] = ["use_demucs": useDemucs ? "true" : "false"]
            if !profile.isEmpty { fields["profile"] = profile }
            // Pre-export to compressed m4a to make upload faster and more reliable
            let uploadURL = await makeUploadFriendlyCopy(from: fileURL)
            let (data, response) = try await TranscriptionAPI.uploadJobStartStreaming(url: uploadURL, endpoint: "/transcribe_start", fields: fields)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
                throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
            }
            let queued = try JSONDecoder().decode(TranscriptionAPI.QueuedJob.self, from: data)
            let finalResp = try await TranscriptionAPI.pollUntilDone(jobId: queued.job_id)
            if finalResp.status == .error {
                throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: finalResp.error ?? "Transcription failed"])
            }

            guard let remote = finalResp.midiURL else {
                throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing MIDI URL in response"])
            }

            let localURL = try await TranscriptionAPI.download(url: remote)
            midiLocalURL = localURL
            notesCount = finalResp.notes
            durationSec = finalResp.duration_sec

            let item = CompletedTranscription(
                id: UUID(),
                sourceFileName: fileURL.lastPathComponent,
                date: Date(),
                midiLocalURL: localURL,
                durationSec: finalResp.duration_sec,
                notes: finalResp.notes
            )
            history.insert(item, at: 0)
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    @MainActor
    func runSeparation(
        fast: Bool = true,
        viaAPI: Bool = false,
        vocalsOnly: Bool = false,
        localSpleeter: Bool = false,
        spleeterOnly: Bool = false
    ) async {
        guard let fileURL = selectedFileURL else { return }
        // Precompute rough ETA from local file duration (heuristic)
        var eta: Int? = nil
        if let u = selectedFileURL {
            let asset = AVURLAsset(url: u)
            let dur = CMTimeGetSeconds(asset.duration)
            if dur.isFinite && dur > 0 {
                // HQ separation often ~0.8x–1.5x realtime locally; choose 1.2x as midpoint
                let mult = fast ? 0.5 : 1.2
                eta = Int(ceil(dur * mult))
            }
        }
        separatingEstimateSec = eta ?? (fast ? 20 : 90)

        isSeparating = true
        separatingElapsedSec = 0
        progressText = viaAPI ? (localSpleeter ? "Separating with local Spleeter…" : "Separating via Spleeter API…") : (fast ? "Separating (fast)…" : "Separating (HQ)…")
        separatingTimer?.invalidate()
        separatingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.separatingElapsedSec += 1
                let base = viaAPI ? (localSpleeter ? "Separating with local Spleeter…" : "Separating via Spleeter API…") : (fast ? "Separating (fast)…" : "Separating (HQ)…")
                if let est = self.separatingEstimateSec, est > 0 {
                    self.separatingProgress = min(1.0, Double(self.separatingElapsedSec) / Double(est))
                    let remaining = max(0, est - self.separatingElapsedSec)
                    self.progressText = base + " " + String(format: "%ds left", remaining)
                } else {
                    self.progressText = base + " " + String(format: "%ds", self.separatingElapsedSec)
                }
            }
        }
        defer { isSeparating = false }
        do {
            if viaAPI {
                let r = try await TranscriptionAPI.separateAudioAPI(url: fileURL, spleeterOnly: spleeterOnly, vocalsOnly: vocalsOnly, localSpleeter: localSpleeter)
                if let i = r.instrumental_url {
                    let localI = try await TranscriptionAPI.download(url: i)
                    instrumentalURL = localI
                }
                if let v = r.vocals_url {
                    let localV = try await TranscriptionAPI.download(url: v)
                    vocalsURL = localV
                }
                separationBackend = r.backend
                // Show a friendly fallback notice if we didn't get the requested hosted/local Spleeter
                if vocalsOnly || localSpleeter || spleeterOnly {
                    let b = (r.backend ?? "").lowercased()
                    if localSpleeter && b != "spleeter_local" {
                        infoMessage = "Local Spleeter not available. Fell back to \(b.replacingOccurrences(of: "_", with: " ")). Result may be approximate."
                    } else if (vocalsOnly || spleeterOnly) && b != "spleeter_api" {
                        infoMessage = "Hosted Spleeter unavailable. Fell back to \(b.replacingOccurrences(of: "_", with: " "))."
                    }
                }
            } else {
                // Choose mode: fast → "fast"; non-fast default lets server pick best (hq).
                // If user hinted "Great", request mode=great with enhancement.
                let wantGreat = (infoMessage ?? "").lowercased().contains("enhance")
                let mode = fast ? "fast" : (wantGreat ? "great" : nil)
                let r = try await TranscriptionAPI.separateAudio(url: fileURL, mode: mode, enhance: wantGreat, queued: true)
                if let i = r.instrumental_url {
                    let localI = try await TranscriptionAPI.download(url: i)
                    instrumentalURL = localI
                }
                if let v = r.vocals_url {
                    let localV = try await TranscriptionAPI.download(url: v)
                    vocalsURL = localV
                }
                separationBackend = r.backend
                if let fb = r.fallback_from, !fb.isEmpty {
                    infoMessage = "Fell back from \(fb) → \(r.backend ?? "")"
                }
            }
            progressText = nil
            separatingProgress = 0
            separatingEstimateSec = nil
        } catch {
            errorMessage = (error as NSError).localizedDescription
            progressText = nil
            separatingProgress = 0
            separatingEstimateSec = nil
        }
        separatingTimer?.invalidate(); separatingTimer = nil
    }

    // Launch helpers to allow cancel from UI
    @MainActor
    func startSeparation(
        fast: Bool = true,
        viaAPI: Bool = false,
        vocalsOnly: Bool = false,
        localSpleeter: Bool = false,
        spleeterOnly: Bool = false
    ) {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runSeparation(
                fast: fast,
                viaAPI: viaAPI,
                vocalsOnly: vocalsOnly,
                localSpleeter: localSpleeter,
                spleeterOnly: spleeterOnly
            )
            await MainActor.run { self?.currentTask = nil }
        }
    }

    @MainActor
    func startTranscription() {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.transcribeSelectedFile()
            await MainActor.run { self?.currentTask = nil }
        }
    }

    @MainActor
    func cancelCurrentWork() {
        currentTask?.cancel(); currentTask = nil
        isUploading = false
        isSeparating = false
        progressText = nil
        separatingProgress = 0
        separatingEstimateSec = nil
        separatingTimer?.invalidate(); separatingTimer = nil
    }

    @MainActor
    func convertInstrumentalToMIDI() async {
        guard let url = instrumentalURL else { return }
        selectedFileURL = url
        await transcribeSelectedFile()
    }

    @MainActor
    func convertVocalsToMIDI() async {
        guard let url = vocalsURL else { return }
        selectedFileURL = url
        await transcribeSelectedFile()
    }

    @MainActor
    func ddspMelodyToPiano() async {
        guard let fileURL = selectedFileURL else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let resp = try await TranscriptionAPI.ddspMelodyToPiano(url: fileURL, render: true)
            // Download MIDI
            let midi = try await TranscriptionAPI.download(url: resp.midi_url)
            midiLocalURL = midi
            notesCount = nil
            durationSec = nil
            if let wavURL = resp.wav_url {
                // Download WAV
                let (data, response) = try await URLSession.shared.data(from: wavURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appending(path: "Transcriptions", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let outURL = folder.appending(path: "\(UUID().uuidString)_melody.wav")
                try data.write(to: outURL)
                lastRenderedWav = outURL
            }
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    @MainActor
    func coverHQ() async {
        guard let fileURL = selectedFileURL else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let resp = try await TranscriptionAPI.pianoCoverHQ(url: fileURL, useDemucs: useDemucs, render: true)
            let midi = try await TranscriptionAPI.download(url: resp.midi_url)
            midiLocalURL = midi
            if let wav = resp.wav_url {
                let (data, response) = try await URLSession.shared.data(from: wav)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appending(path: "Transcriptions", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let outURL = folder.appending(path: "\(UUID().uuidString)_cover_hq.wav")
                try data.write(to: outURL)
                lastRenderedWav = outURL
            }
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    @MainActor
    func coverStyleRun() async {
        guard let fileURL = selectedFileURL else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let resp = try await TranscriptionAPI.pianoCoverStyle(url: fileURL, style: coverStyle, useDemucs: useDemucs, render: true)
            let midi = try await TranscriptionAPI.download(url: resp.midi_url)
            midiLocalURL = midi
            if let wav = resp.wav_url {
                let (data, response) = try await URLSession.shared.data(from: wav)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appending(path: "Transcriptions", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let outURL = folder.appending(path: "\(UUID().uuidString)_cover_\(coverStyle).wav")
                try data.write(to: outURL)
                lastRenderedWav = outURL
            }
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    @MainActor
    func renderAudio(from midiURL: URL) async throws -> URL {
		var request = URLRequest(url: Config.serverBaseURL.appending(path: "/render"))
        request.httpMethod = "POST"
		request.timeoutInterval = 600
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try Data(contentsOf: midiURL)
        var body = Data()
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
		// Additional field: ask server for a faster render profile to keep CPU cooler during dev
		append("--\(boundary)\r\n")
		append("Content-Disposition: form-data; name=\"quality\"\r\n\r\n")
		append("basic\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"midi\"; filename=\"file.mid\"\r\n")
        append("Content-Type: audio/midi\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

		let config = URLSessionConfiguration.default
		config.timeoutIntervalForRequest = 600
		config.timeoutIntervalForResource = 600
		let session = URLSession(configuration: config)

		let (respData, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let txt = String(data: respData, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: txt])
        }

        struct RenderResp: Decodable { let wav_url: URL }
        let parsed = try JSONDecoder().decode(RenderResp.self, from: respData)

        // Download the WAV
		let (wavData, wavResp) = try await session.data(from: parsed.wav_url)
        guard let http2 = wavResp as? HTTPURLResponse, (200..<300).contains(http2.statusCode) else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed downloading WAV"]) 
        }
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Transcriptions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outURL = folder.appending(path: "\(UUID().uuidString).wav")
        try wavData.write(to: outURL)
        return outURL
    }

    @MainActor
    func renderAudioSFZ(from midiURL: URL) async throws -> URL {
		var request = URLRequest(url: Config.serverBaseURL.appending(path: "/render_sfizz"))
        request.httpMethod = "POST"
		request.timeoutInterval = 600
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try Data(contentsOf: midiURL)
        var body = Data()
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
		// Render at 44.1kHz to reduce CPU load during development
		append("--\(boundary)\r\n")
		append("Content-Disposition: form-data; name=\"sr\"\r\n\r\n")
		append("44100\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"midi\"; filename=\"file.mid\"\r\n")
        append("Content-Type: audio/midi\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

		let config = URLSessionConfiguration.default
		config.timeoutIntervalForRequest = 600
		config.timeoutIntervalForResource = 600
		let session = URLSession(configuration: config)

		let (respData, response) = try await session.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let txt = String(data: respData, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: txt])
        }
        struct RenderResp: Decodable { let wav_url: URL }
        let parsed = try JSONDecoder().decode(RenderResp.self, from: respData)

		let (wavData, wavResp) = try await session.data(from: parsed.wav_url)
        guard let http2 = wavResp as? HTTPURLResponse, (200..<300).contains(http2.statusCode) else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed downloading WAV"]) 
        }
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Transcriptions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outURL = folder.appending(path: "\(UUID().uuidString)_sfz.wav")
        try wavData.write(to: outURL)
        return outURL
    }
    @MainActor
    func enhancePerformance(midiURL: URL) async throws -> URL {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/perform"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try Data(contentsOf: midiURL)
        var body = Data()
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"midi\"; filename=\"file.mid\"\r\n")
        append("Content-Type: audio/midi\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let (respData, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let txt = String(data: respData, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: txt])
        }
        struct Resp: Decodable { let midi_url: URL }
        let parsed = try JSONDecoder().decode(Resp.self, from: respData)
        let (midData, midResp) = try await URLSession.shared.data(from: parsed.midi_url)
        guard let http2 = midResp as? HTTPURLResponse, (200..<300).contains(http2.statusCode) else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed downloading performed MIDI"]) 
        }
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Transcriptions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outURL = folder.appending(path: "\(UUID().uuidString)_performed.mid")
        try midData.write(to: outURL)
        return outURL
    }

    @MainActor
    func enhancePerformanceML(midiURL: URL) async throws -> URL {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/perform_ml"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try Data(contentsOf: midiURL)
        var body = Data()
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"midi\"; filename=\"file.mid\"\r\n")
        append("Content-Type: audio/midi\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        let (respData, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let txt = String(data: respData, encoding: .utf8) ?? "Server error"
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: txt])
        }
        struct Resp: Decodable { let midi_url: URL }
        let parsed = try JSONDecoder().decode(Resp.self, from: respData)
        let (midData, midResp) = try await URLSession.shared.data(from: parsed.midi_url)
        guard let http2 = midResp as? HTTPURLResponse, (200..<300).contains(http2.statusCode) else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed downloading ML performed MIDI"]) 
        }
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Transcriptions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outURL = folder.appending(path: "\(UUID().uuidString)_performed_ml.mid")
        try midData.write(to: outURL)
        return outURL
    }
}


