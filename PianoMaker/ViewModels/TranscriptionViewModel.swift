import Foundation
import SwiftUI
import AVFoundation
import Network

@MainActor
final class TranscriptionViewModel: ObservableObject {
    @Published var selectedFileURL: URL?
    @Published var midiLocalURL: URL?
    @Published var isUploading: Bool = false
    @Published var errorMessage: String?

    @Published var notesCount: Int?
    @Published var durationSec: Double?
    @Published var history: [CompletedTranscription] = []
    @Published var transcriptionMode: String = "pure" // pure, enhanced
    @Published var instrumentalURL: URL?
    @Published var vocalsURL: URL?
    @Published var isSeparating: Bool = false
    @Published var progressText: String? // shows simple loading state
    @Published var lastRenderedWav: URL?

    // Great Quality separation is the only mode available // standard, pro, speed
    @Published var separationBackend: String? // displays backend used
    @Published var separationSource: String? // displays source: "cloud", "local", "cloud_forced", etc.
    @Published var separationCloudModel: String? // displays cloud model used: "ryan5453/demucs", etc.
    // Single high-quality separation only (no modes)
    @Published var selectedSoundFont: TranscriptionAPI.SoundFont = .generalUser
    @Published var renderingQuality: String = "studio" // studio, high, low
    @Published var midiURL: URL? // Remote MIDI URL for sharing
    @Published var infoMessage: String?
    @Published var separatingElapsedSec: Int = 0
    @Published var separatingEstimateSec: Int?
    @Published var separatingProgress: Double = 0
    @Published var networkStatus: String = "Unknown"
    @Published var serverReachable: Bool = false
    @Published var lastErrorDetails: String?
    
    private var separatingTimer: Timer?
    private var currentTask: Task<Void, Never>?
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "NetworkMonitor")

    init() {
        startNetworkMonitoring()
        Task { await checkServerConnectivity() }
    }
    
    deinit {
        networkMonitor.cancel()
    }
    
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.updateNetworkStatus(path)
            }
        }
        networkMonitor.start(queue: networkQueue)
    }
    
    private func updateNetworkStatus(_ path: NWPath) {
        switch path.status {
        case .satisfied:
            networkStatus = "Connected"
            if path.usesInterfaceType(.wifi) {
                networkStatus += " (WiFi)"
            } else if path.usesInterfaceType(.cellular) {
                networkStatus += " (Cellular)"
            }
        case .unsatisfied:
            networkStatus = "No Connection"
        case .requiresConnection:
            networkStatus = "Connecting..."
        @unknown default:
            networkStatus = "Unknown"
        }
    }
    
    private func checkServerConnectivity() async {
        let serverURL = Config.serverBaseURL
        let healthURL = serverURL.appending(path: "/health")
        
        do {
                    let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10.0  // 10 seconds for health check
        config.timeoutIntervalForResource = 15.0 // 15 seconds total for health check
            let session = URLSession(configuration: config)
            
            let (data, response) = try await session.data(from: healthURL)
            
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    serverReachable = true
                    infoMessage = "Server connected: \(serverURL.absoluteString)"
                    errorMessage = nil
                } else {
                    serverReachable = false
                    let bodyText = String(data: data, encoding: .utf8) ?? "No response body"
                    errorMessage = "Server error: HTTP \(http.statusCode) - \(bodyText)"
                    lastErrorDetails = "HTTP Status: \(http.statusCode)\nResponse: \(bodyText)"
                }
            } else {
                serverReachable = false
                errorMessage = "Invalid response from server"
                lastErrorDetails = "Response type: \(type(of: response))"
            }
        } catch {
            serverReachable = false
            let nsError = error as NSError
            errorMessage = "Cannot reach server: \(nsError.localizedDescription)"
            lastErrorDetails = """
            Error Domain: \(nsError.domain)
            Error Code: \(nsError.code)
            Description: \(nsError.localizedDescription)
            Server URL: \(serverURL.absoluteString)
            Network Status: \(networkStatus)
            """
        }
    }
    
    func refreshServerStatus() async {
        await checkServerConnectivity()
    }
    
    func forceRefreshServerConfig() async {
        // Clear any cached errors first
        clearErrors()
        // Force a fresh server connectivity check
        await checkServerConnectivity()
    }
    
    func forceReconnectToServer() async {
        // Clear all state and force a fresh connection
        resetState()
        // Force a fresh server connectivity check
        await checkServerConnectivity()
    }
    
    func clearErrors() {
        errorMessage = nil
        lastErrorDetails = nil
        infoMessage = nil
    }
    
    func resetState() {
        clearErrors()
        isUploading = false
        isSeparating = false
        progressText = nil
        separatingProgress = 0
        separatingEstimateSec = nil
        separatingTimer?.invalidate()
        separatingTimer = nil
        currentTask?.cancel()
        currentTask = nil
    }

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
        errorMessage = nil
        lastErrorDetails = nil
        currentTask?.cancel(); currentTask = nil
    }

    @MainActor
    func transcribeSelectedFile() async {
        guard let fileURL = selectedFileURL else { return }
        
        // Check server connectivity first
        if !serverReachable {
            errorMessage = "Server is not reachable. Please check your connection and try again."
            await checkServerConnectivity()
            return
        }
        
        isUploading = true
        defer { isUploading = false }

        // Add timeout mechanism to prevent infinite loading
        let maxTranscriptionTime: TimeInterval = 600 // 10 minutes max for transcription
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(maxTranscriptionTime * 1_000_000_000))
            await MainActor.run {
                if isUploading {
                    errorMessage = "Transcription timed out after 10 minutes. Please check server status and try again."
                    lastErrorDetails = """
                    Transcription Timeout:
                    Max Allowed: \(Int(maxTranscriptionTime))s
                    Server Reachable: \(serverReachable)
                    File: \(fileURL.lastPathComponent)
                    """
                }
            }
        }
        
        defer { timeoutTask.cancel() }

        do {
            // Try streaming/async path first to avoid client timeouts on long songs
            var fields: [String:String] = [:]
            fields["mode"] = transcriptionMode
            
            print("🎵 DEBUG: Starting transcription with mode: \(transcriptionMode)")
            print("🎵 DEBUG: Fields: \(fields)")
            print("🎵 DEBUG: Server URL: \(Config.serverBaseURL.absoluteString)")
            print("🎵 DEBUG: File: \(fileURL.lastPathComponent)")
            
            // Pre-export to compressed m4a to make upload faster and more reliable
            let uploadURL = await makeUploadFriendlyCopy(from: fileURL)
            print("🎵 DEBUG: Upload URL prepared: \(uploadURL.lastPathComponent)")
            
            let (data, response) = try await TranscriptionAPI.uploadJobStartStreaming(url: uploadURL, endpoint: "/transcribe_start", fields: fields)
            
            print("🎵 DEBUG: Initial response received")
            print("🎵 DEBUG: Response data length: \(data.count)")
            if let responseText = String(data: data, encoding: .utf8) {
                print("🎵 DEBUG: Response body: \(responseText)")
            }
            
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
                let errorMsg = "Transcription failed: HTTP \(http.statusCode) - \(bodyText)"
                print("🎵 DEBUG: HTTP Error: \(errorMsg)")
                errorMessage = errorMsg
                lastErrorDetails = """
                HTTP Status: \(http.statusCode)
                Response Body: \(bodyText)
                Server URL: \(Config.serverBaseURL.absoluteString)
                """
                throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
            
            let queued = try JSONDecoder().decode(TranscriptionAPI.QueuedJob.self, from: data)
            print("🎵 DEBUG: Queued job received: \(queued.job_id)")
            
            let finalResp = try await TranscriptionAPI.pollUntilDone(jobId: queued.job_id)
            print("🎵 DEBUG: Final response received")
            print("🎵 DEBUG: Status: \(finalResp.status)")
            print("🎵 DEBUG: MIDI URL: \(finalResp.midiURL?.absoluteString ?? "nil")")
            print("🎵 DEBUG: Notes: \(finalResp.notes ?? -1)")
            print("🎵 DEBUG: Duration: \(finalResp.duration_sec ?? -1)")
            
            if finalResp.status == .error {
                let errorMsg = "Transcription failed: \(finalResp.error ?? "Unknown error")"
                print("🎵 DEBUG: Job failed with error: \(errorMsg)")
                errorMessage = errorMsg
                lastErrorDetails = """
                Job Status: \(finalResp.status)
                Error: \(finalResp.error ?? "None")
                Job ID: \(queued.job_id)
                """
                throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }

            guard let remote = finalResp.midiURL else {
                let errorMsg = "Missing MIDI URL in response"
                print("🎵 DEBUG: Missing MIDI URL in response!")
                print("🎵 DEBUG: Full response: \(finalResp)")
                errorMessage = errorMsg
                lastErrorDetails = """
                Response Status: \(finalResp.status)
                MIDI URL: nil
                Notes: \(finalResp.notes ?? 0)
                Duration: \(finalResp.duration_sec ?? 0)
                """
                throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }

            // Get local copy of the MIDI file
            let localURL = try await copyRemoteFileToLocal(remote)
            midiLocalURL = localURL
            notesCount = finalResp.notes
            durationSec = finalResp.duration_sec
            errorMessage = nil
            lastErrorDetails = nil

            let item = CompletedTranscription(
                id: UUID(),
                sourceFileName: fileURL.lastPathComponent,
                date: Date(),
                midiLocalURL: localURL,
                durationSec: finalResp.duration_sec,
                notes: finalResp.notes
            )
            history.insert(item, at: 0)
            
            // Store the remote MIDI URL for sharing
            if let midiURL = finalResp.midiURL {
                self.midiURL = midiURL // Store for sharing
            }
        } catch {
            let nsError = error as NSError
            if errorMessage == nil {
                errorMessage = nsError.localizedDescription
            }
            if lastErrorDetails == nil {
                lastErrorDetails = """
                Error Domain: \(nsError.domain)
                Error Code: \(nsError.code)
                Description: \(nsError.localizedDescription)
                User Info: \(nsError.userInfo)
                """
            }
        }
    }

    @MainActor
    func runSeparation() async {
        guard let fileURL = selectedFileURL else { return }
        
        // Check server connectivity first
        if !serverReachable {
            errorMessage = "Server is not reachable. Please check your connection and try again."
            await checkServerConnectivity()
            return
        }
        
        // Precompute rough ETA from local file duration (heuristic)
        var eta: Int? = nil
        if let u = selectedFileURL {
            let asset = AVURLAsset(url: u)
            let dur = CMTimeGetSeconds(asset.duration)
            if dur.isFinite && dur > 0 {
                // HQ separation often ~1.2x realtime
                eta = Int(ceil(dur * 1.2))
            }
        }
        separatingEstimateSec = eta ?? 90

        isSeparating = true
        separatingElapsedSec = 0
        progressText = "Separating with high quality…"
        separatingTimer?.invalidate()
        
        // Add timeout mechanism to prevent infinite loading
        let maxSeparationTime: TimeInterval = 900 // 15 minutes max to match backend polling
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(maxSeparationTime * 1_000_000_000))
            await MainActor.run {
                if isSeparating {
                    errorMessage = "Separation timed out after 5 minutes. Please check server status and try again."
                    lastErrorDetails = """
                    Separation Timeout:
                    Elapsed Time: \(separatingElapsedSec)s
                    Estimated Time: \(separatingEstimateSec ?? 0)s
                    Max Allowed: \(Int(maxSeparationTime))s
                    Server Reachable: \(serverReachable)
                    """
                    cancelCurrentWork()
                }
            }
        }
        
        separatingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.separatingElapsedSec += 1
                let base = "Separating with high quality…"
                if let est = self.separatingEstimateSec, est > 0 {
                    self.separatingProgress = min(1.0, Double(self.separatingElapsedSec) / Double(est))
                    let remaining = max(0, est - self.separatingElapsedSec)
                    self.progressText = base + " " + String(format: "%ds left", remaining)
                } else {
                    self.progressText = base + " " + String(format: "%ds", self.separatingElapsedSec)
                }
            }
        }
        defer { 
            isSeparating = false
            timeoutTask.cancel()
        }
        
        do {
            // Use single high-quality separation endpoint (no modes)
            let r = try await TranscriptionAPI.separateAudio(url: fileURL, queued: true)
            
            print("🎵 DEBUG: Separation response received:")
            print("🎵 DEBUG: - Status: \(r.status)")
            print("🎵 DEBUG: - Job ID: \(r.job_id)")
            print("🎵 DEBUG: - Instrumental URL: \(r.instrumental_url?.absoluteString ?? "nil")")
            print("🎵 DEBUG: - Vocals URL: \(r.vocals_url?.absoluteString ?? "nil")")
            print("🎵 DEBUG: - Backend: \(r.backend ?? "nil")")
            print("🎵 DEBUG: - Source: \(r.source ?? "nil")")
            print("🎵 DEBUG: - Cloud Model: \(r.cloud_model ?? "nil")")
            
            // Check if we actually got URLs
            if r.instrumental_url == nil && r.vocals_url == nil {
                print("🚨 ERROR: Both instrumental and vocals URLs are nil!")
                throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Separation completed but no audio files were returned"])
            }
            
            if let i = r.instrumental_url {
                print("🎵 DEBUG: Downloading instrumental from: \(i.absoluteString)")
                let localI = try await copyRemoteFileToLocal(i)
                print("🎵 DEBUG: Instrumental downloaded to: \(localI.absoluteString)")
                instrumentalURL = localI
            } else {
                print("🚨 ERROR: No instrumental URL in response!")
            }
            
            if let v = r.vocals_url {
                print("🎵 DEBUG: Downloading vocals from: \(v.absoluteString)")
                let localV = try await copyRemoteFileToLocal(v)
                print("🎵 DEBUG: Vocals downloaded to: \(localV.absoluteString)")
                vocalsURL = localV
            } else {
                print("🚨 ERROR: No vocals URL in response!")
            }
            
            separationBackend = r.backend
            separationSource = r.source
            separationCloudModel = r.cloud_model
            
            print("🎵 DEBUG: Final state after processing:")
            print("🎵 DEBUG: - instrumentalURL: \(instrumentalURL?.absoluteString ?? "nil")")
            print("🎵 DEBUG: - vocalsURL: \(vocalsURL?.absoluteString ?? "nil")")
            print("🎵 DEBUG: - separationBackend: \(separationBackend ?? "nil")")
            print("🎵 DEBUG: - separationSource: \(separationSource ?? "nil")")
            print("🎵 DEBUG: - separationCloudModel: \(separationCloudModel ?? "nil")")
            
            // Verify we have at least one track
            if instrumentalURL == nil && vocalsURL == nil {
                print("🚨 CRITICAL ERROR: Both tracks failed to download!")
                throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to download any audio tracks from separation"])
            }
            
            infoMessage = "High-quality separation completed successfully!"
            
            progressText = nil
            separatingProgress = 0
            separatingEstimateSec = nil
            errorMessage = nil
            lastErrorDetails = nil
        } catch {
            let nsError = error as NSError
            if errorMessage == nil {
                errorMessage = nsError.localizedDescription
            }
            if lastErrorDetails == nil {
                lastErrorDetails = """
                Separation Error:
                Domain: \(nsError.domain)
                Code: \(nsError.code)
                Description: \(nsError.localizedDescription)
                User Info: \(nsError.userInfo)
                """
            }
            progressText = nil
            separatingProgress = 0
            separatingEstimateSec = nil
        }
        separatingTimer?.invalidate(); separatingTimer = nil
    }

    // Launch helpers to allow cancel from UI
    @MainActor
    func startSeparation() {
        currentTask?.cancel()
        
        // Clear previous separation results
        instrumentalURL = nil
        vocalsURL = nil
        separationBackend = nil
        separationSource = nil
        separationCloudModel = nil
        infoMessage = nil
        
        currentTask = Task { [weak self] in
            await self?.runSeparation()
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
        
        // Clear separation results when canceling
        if isSeparating {
            instrumentalURL = nil
            vocalsURL = nil
            separationBackend = nil
            separationSource = nil
            separationCloudModel = nil
        }
        
        // Clear any pending errors when canceling
        if isUploading || isSeparating {
            errorMessage = "Operation was cancelled by user"
            lastErrorDetails = """
            Operation Cancelled:
            Uploading: \(isUploading)
            Separating: \(isSeparating)
            Time: \(Date().formatted())
            """
        }
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
    
    // MARK: - File Operations
    
    private func copyRemoteFileToLocal(_ remoteURL: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch remote file"])
        }
        
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Transcriptions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        
        let filename = remoteURL.lastPathComponent.isEmpty ? "\(UUID().uuidString).mid" : remoteURL.lastPathComponent
        let localURL = folder.appending(path: filename)
        try data.write(to: localURL)
        return localURL
    }
    
    // MARK: - Rendering
    
    @MainActor
    func renderMIDI(midiData: Data) async {
        isUploading = true
        defer { isUploading = false }
        
        do {
            print("🎵 DEBUG: Starting render with SoundFont: \(selectedSoundFont.rawValue)")
            let jobId = try await TranscriptionAPI.startRender(
                midiData: midiData,
                soundFont: selectedSoundFont,
                preview: true,
                quality: renderingQuality
            )
            
            print("🎵 DEBUG: Render job started: \(jobId)")
            
            // Poll for completion
            let maxWaitTime: TimeInterval = 900 // 15 minutes
            let startTime = Date()
            
            while Date().timeIntervalSince(startTime) < maxWaitTime {
                let status = try await TranscriptionAPI.pollRenderJob(jobId: jobId)
                print("🎵 DEBUG: Render status: \(status.status)")
                
                if status.status == "done" {
                    if let wavURL = status.wav_url {
                        lastRenderedWav = wavURL
                        print("🎵 DEBUG: Render completed: \(wavURL)")
                    }
                    break
                } else if status.status == "error" {
                    throw NSError(domain: "Render", code: -1, userInfo: [NSLocalizedDescriptionKey: "Rendering failed"])
                }
                
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }
            
        } catch {
            print("🎵 DEBUG: Render error: \(error)")
            errorMessage = "Rendering failed: \(error.localizedDescription)"
        }
    }
    

}


