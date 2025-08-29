import Foundation

enum APIError: Error {
    case badResponse
    case invalidURL
}

struct TranscriptionAPI {
    struct QueuedJob: Decodable { let status: String; let job_id: String }
    struct RenderResult: Decodable { let status: String; let wav_url: URL; let job_id: String }
    struct JobStatus: Decodable { 
        let status: String; 
        let progress: Double?; 
        let wav_url: URL?; 
        let instrumental_url: URL?; 
        let vocals_url: URL?; 
        let output_url: URL?;
        let file_size: Int?;
        let backend: String?; 
        let fallback_from: String?;
        let error: String?
    }
    struct SeparationResp: Decodable { 
        let status: String; 
        let job_id: String; 
        let instrumental_url: URL?; 
        let vocals_url: URL?; 
        let backend: String?; 
        let fallback_from: String?;
        let source: String?;  // New field: "cloud", "local", etc.
        let cloud_model: String?  // New field: model used for cloud processing
    }
    struct AudioProcessingResp: Decodable { let status: String; let job_id: String; let output_url: URL?; let file_size: Int? }

    static func uploadAudio(url: URL) async throws -> TranscriptionResponse {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/transcribe"))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: [:], boundary: boundary)

        // Use reasonable timeouts for conversions
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60.0   // 1 minute for initial connection
        config.timeoutIntervalForResource = 300.0 // 5 minutes total for upload
        let session = URLSession(configuration: config)
        let (data, response) = try await session.upload(for: request, from: formData)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return try decoder.decode(TranscriptionResponse.self, from: data)
    }

    static func processAudio(url: URL, queued: Bool = true) async throws -> AudioProcessingResp {
        let endpoint = queued ? "/process_audio_job" : "/process_audio"
        // Use streaming multipart upload for reliability with large files and on Simulator
        let fields: [String: String] = ["output_format": "wav"]
        let (data, response) = try await uploadJobStartStreaming(url: url, endpoint: endpoint, fields: fields)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        // If queued, poll /job/{id} until we get the processed audio URL
        if queued {
            struct Queued: Decodable { let status: String; let job_id: String }
            let queuedResp = try JSONDecoder().decode(Queued.self, from: data)
            let jobId = queuedResp.job_id
            
            let startTime = Date()
            let maxWaitTime: TimeInterval = 300 // 5 minutes max wait
            let pollInterval: TimeInterval = 1.0 // Poll every second
            
            while Date().timeIntervalSince(startTime) < maxWaitTime {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                let status = try await pollAudioProcessingJob(jobId: jobId)
                if status.status == "done" || status.output_url != nil {
                    return AudioProcessingResp(status: status.status, job_id: jobId, output_url: status.output_url, file_size: status.file_size)
                }
                if status.status == "error" {
                    let errorMsg = status.error ?? "Audio processing failed"
                    throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
                }
            }
            
            // Timeout reached
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio processing job timed out after 5 minutes. Please check server status."])
        } else {
            return try JSONDecoder().decode(AudioProcessingResp.self, from: data)
        }
    }



    static func uploadAudioPTI(url: URL) async throws -> TranscriptionResponse {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/transcribe_pti"))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: [:], boundary: boundary)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60.0   // 1 minute for initial connection
        config.timeoutIntervalForResource = 300.0 // 5 minutes total for upload
        let session = URLSession(configuration: config)
        let (data, response) = try await session.upload(for: request, from: formData)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return try decoder.decode(TranscriptionResponse.self, from: data)
    }

    static func pollTranscriptionJob(jobId: String) async throws -> JobStatus {
        let url = Config.serverBaseURL.appending(path: "/job/\(jobId)")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30.0   // 30 seconds for polling
        cfg.timeoutIntervalForResource = 60.0  // 1 minute total for polling
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }

    static func pollUntilDone(jobId: String) async throws -> TranscriptionResponse {
        let startTime = Date()
                    let maxWaitTime: TimeInterval = 900 // 15 minutes max wait
        let pollInterval: TimeInterval = 1.0 // Poll every second
        
        print("🎵 DEBUG: Starting to poll job: \(jobId)")
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            let status = try await pollJob(jobId: jobId) // This now calls the separation-specific pollJob
            print("🎵 DEBUG: Job \(jobId) status: \(status.status)")
            
            switch status.status {
            case "done":
                // Job completed, get the final result
                print("🎵 DEBUG: Job completed, fetching final result...")
                let finalURL = Config.serverBaseURL.appending(path: "/job/\(jobId)")
                print("🎵 DEBUG: Fetching from: \(finalURL.absoluteString)")
                
                let (data, response) = try await URLSession.shared.data(from: finalURL)
                print("🎵 DEBUG: Final response data length: \(data.count)")
                
                if let responseText = String(data: data, encoding: .utf8) {
                    print("🎵 DEBUG: Final response body: \(responseText)")
                }
                
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
                    print("🎵 DEBUG: HTTP error in final response: \(http.statusCode) - \(bodyText)")
                    throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
                }
                
                let finalResponse = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
                print("🎵 DEBUG: Decoded final response: \(finalResponse)")
                return finalResponse
                
            case "error":
                let errorMsg = status.error ?? "Job failed with unknown error"
                print("🎵 DEBUG: Job failed with error: \(errorMsg)")
                throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
                
            case "processing", "queued":
                // Continue polling
                print("🎵 DEBUG: Job still processing, waiting \(pollInterval)s...")
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                continue
                
            default:
                // Unknown status, continue polling
                print("🎵 DEBUG: Unknown status '\(status.status)', continuing to poll...")
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                continue
            }
        }
        
        // Timeout reached
        print("🎵 DEBUG: Job polling timed out after \(maxWaitTime)s")
        throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Job timed out after 5 minutes. Please check server status."])
    }

    static func transcribeStart(url: URL, mode: String = "pure") async throws -> QueuedJob {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/transcribe_start"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields: [String: String] = [:]
        fields["mode"] = mode
        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: fields, boundary: boundary)
        let cfg = URLSessionConfiguration.ephemeral
        // Reasonable timeouts to prevent hanging
        cfg.timeoutIntervalForRequest = 60.0   // 1 minute for initial connection
        cfg.timeoutIntervalForResource = 300.0 // 5 minutes total for upload
        let session = URLSession(configuration: cfg)
        let (data, response) = try await uploadWithRetry(session: session, request: request, body: formData, retries: 3)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try JSONDecoder().decode(QueuedJob.self, from: data)
    }


    

    

    


    // SoundFont options for users to choose from
    enum SoundFont: String, CaseIterable {
        case fluidR3_GM = "FluidR3_GM.sf2"
        case generalUser = "GeneralUser_GS_v1.471.sf2"
        case salamanderGrand = "SalamanderGrandPianoV3.sfz"
        case salamanderRetuned = "SalamanderGrandPianoV3Retuned.sfz"
        
        var description: String {
            switch self {
            case .fluidR3_GM:
                return "General MIDI - Studio quality, all instruments"
            case .generalUser:
                return "GeneralUser GS - Better quality than FluidR3, free"
            case .salamanderGrand:
                return "Salamander Grand Piano - Rich acoustic piano"
            case .salamanderRetuned:
                return "Salamander Retuned - Alternative piano tuning"
            }
        }
        
        var type: String {
            switch self {
            case .fluidR3_GM, .generalUser: return "sf2"
            case .salamanderGrand, .salamanderRetuned: return "sfz"
            }
        }
        
        var endpoint: String {
            switch self {
            case .fluidR3_GM, .generalUser: return "/render"
            case .salamanderGrand, .salamanderRetuned: return "/render_sfizz"
            }
        }
    }
    
    static func renderDirectly(midiData: Data, soundFont: SoundFont, quality: String = "studio") async throws -> RenderResult {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: soundFont.endpoint))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        
        // Add quality parameter for FluidSynth (sf2)
        if soundFont.type == "sf2" {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"quality\"\r\n\r\n")
            append("\(quality)\r\n")
        }
        
        // Add sample rate for SFizz (sfz)
        if soundFont.type == "sfz" {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"sfz\"\r\n\r\n")
            append("\(soundFont.rawValue)\r\n")
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"sr\"\r\n\r\n")
            append("44100\r\n")
        }
        
        // Add MIDI file
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"midi\"; filename=\"file.mid\"\r\n")
        append("Content-Type: audio/midi\r\n\r\n")
        body.append(midiData)
        append("\r\n--\(boundary)--\r\n")
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.upload(for: request, from: body)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        
        return try JSONDecoder().decode(RenderResult.self, from: data)
    }
    
    static func startRender(midiData: Data, soundFont: SoundFont, preview: Bool = true, quality: String = "studio") async throws -> String {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: soundFont.endpoint))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        
        // Add quality parameter for FluidSynth (sf2)
        if soundFont.type == "sf2" {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"quality\"\r\n\r\n")
            append("\(quality)\r\n")
        }
        
        // Add sample rate for SFizz (sfz)
        if soundFont.type == "sfz" {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"sfz\"\r\n\r\n")
            append("\(soundFont.rawValue)\r\n")
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"sr\"\r\n\r\n")
            append("44100\r\n")
        }
        
        // Add MIDI file
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"midi\"; filename=\"file.mid\"\r\n")
        append("Content-Type: audio/midi\r\n\r\n")
        body.append(midiData)
        append("\r\n--\(boundary)--\r\n")
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.upload(for: request, from: body)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        
        return try JSONDecoder().decode(QueuedJob.self, from: data).job_id
    }
    
    // Keep the old function for backward compatibility
    static func startRenderSFZ(midiData: Data, preview: Bool = true) async throws -> String {
        return try await startRender(midiData: midiData, soundFont: .salamanderGrand, preview: preview)
    }

    static func pollRenderJob(jobId: String) async throws -> JobStatus {
        let url = Config.serverBaseURL.appending(path: "/job/\(jobId)")
        
        // Add timeout to prevent hanging
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10.0 // 10 second timeout for each poll
        config.timeoutIntervalForResource = 10.0
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try JSONDecoder().decode(JobStatus.self, from: data)
    }

    struct SepJobStatus: Decodable {
        let status: String
        let progress: Double?
        let instrumental_url: URL?
        let vocals_url: URL?
        let output_url: URL?
        let file_size: Int?
        let backend: String?
        let fallback_from: String?
        let error: String?
        let source: String?  // New field: "cloud", "local", etc.
        let cloud_model: String?  // New field: model used for cloud processing
    }
    static func pollJob(jobId: String) async throws -> SepJobStatus {
        let url = Config.serverBaseURL.appending(path: "/job/\(jobId)")
        print("🎵 DEBUG: Polling job status from: \(url.absoluteString)")
        
        // Add timeout to prevent hanging
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10.0 // 10 second timeout for each poll
        config.timeoutIntervalForResource = 10.0
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(from: url)
        print("🎵 DEBUG: Job status response data length: \(data.count)")
        
        if let responseText = String(data: data, encoding: .utf8) {
            print("🎵 DEBUG: Job status response body: \(responseText)")
        }
        
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            print("🎵 DEBUG: HTTP error polling job: \(http.statusCode) - \(bodyText)")
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        
        let status = try JSONDecoder().decode(SepJobStatus.self, from: data)
        print("🎵 DEBUG: Decoded job status: \(status)")
        return status
    }
    
    static func pollAudioProcessingJob(jobId: String) async throws -> SepJobStatus {
        let url = Config.serverBaseURL.appending(path: "/job/\(jobId)")
        print("🎵 DEBUG: Polling audio processing job status from: \(url.absoluteString)")
        
        // Add timeout to prevent hanging
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10.0 // 10 second timeout for each poll
        config.timeoutIntervalForResource = 10.0
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(from: url)
        print("🎵 DEBUG: Audio processing job status response data length: \(data.count)")
        
        if let responseText = String(data: data, encoding: .utf8) {
            print("🎵 DEBUG: Audio processing job status response body: \(responseText)")
        }
        
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            print("🎵 DEBUG: HTTP error polling audio processing job: \(http.statusCode) - \(bodyText)")
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        
        let status = try JSONDecoder().decode(SepJobStatus.self, from: data)
        print("🎵 DEBUG: Decoded audio processing job status: \(status)")
        return status
    }
    
    static func separateAudio(url: URL, queued: Bool = true, mode: String = "htdemucs") async throws -> SeparationResp {
        let endpoint = "/separate_audio"
        var request = URLRequest(url: Config.serverBaseURL.appending(path: endpoint))
        request.httpMethod = "POST"
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var fields: [String: String] = [:]
        fields["mode"] = mode
        
        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: fields, boundary: boundary)
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60.0   // 1 minute for initial connection
        config.timeoutIntervalForResource = 60.0  // 1 minute total for upload
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.upload(for: request, from: formData)
        
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        
        // Parse the response to get job ID
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        
        struct SeparationJobResponse: Decodable {
            let status: String
            let job_id: String
            let message: String
        }
        
        let jobResponse = try decoder.decode(SeparationJobResponse.self, from: data)
        
        if jobResponse.status != "started" {
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start separation job"])
        }
        
        // Poll for completion
        let startTime = Date()
        let maxWaitTime: TimeInterval = 600 // 10 minutes max wait
        let pollInterval: TimeInterval = 2.0 // Poll every 2 seconds
        
        print("🎵 DEBUG: Starting job polling loop for job: \(jobResponse.job_id)")
        
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            
            print("🎵 DEBUG: Polling job \(jobResponse.job_id) (attempt \(Int(Date().timeIntervalSince(startTime) / pollInterval) + 1))")
            let status = try await pollSeparationJob(jobId: jobResponse.job_id)
            
            print("🎵 DEBUG: Job \(jobResponse.job_id) status: \(status.status)")
            
            if status.status == "done" {
                print("🎵 DEBUG: Job \(jobResponse.job_id) completed successfully!")
                print("🎵 DEBUG: - Instrumental URL: \(status.instrumental_url?.absoluteString ?? "nil")")
                print("🎵 DEBUG: - Vocals URL: \(status.vocals_url?.absoluteString ?? "nil")")
                
                // Job completed, return the results
                return SeparationResp(
                    status: status.status,
                    job_id: jobResponse.job_id,
                    instrumental_url: status.instrumental_url,
                    vocals_url: status.vocals_url,
                    backend: "demucs",
                    fallback_from: nil,
                    source: status.source,
                    cloud_model: status.cloud_model
                )
            }
            
            if status.status == "error" {
                let errorMsg = status.error ?? "Separation failed with unknown error"
                print("🚨 ERROR: Job \(jobResponse.job_id) failed: \(errorMsg)")
                throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
            }
            
            print("🎵 DEBUG: Job \(jobResponse.job_id) still processing, continuing to poll...")
            // Continue polling for "processing" or "queued" status
        }
        
        // Timeout reached
        print("🚨 ERROR: Job \(jobResponse.job_id) timed out after 10 minutes")
        throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: "Separation job timed out after 10 minutes"])
    }
    
    static func pollSeparationJob(jobId: String) async throws -> SepJobStatus {
        let url = Config.serverBaseURL.appending(path: "/job/\(jobId)")
        print("🎵 DEBUG: Polling separation job status from: \(url.absoluteString)")
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10.0 // 10 second timeout for each poll
        config.timeoutIntervalForResource = 10.0
        let session = URLSession(configuration: config)
        
        let (data, response) = try await session.data(from: url)
        print("🎵 DEBUG: Separation job status response data length: \(data.count)")
        
        if let responseText = String(data: data, encoding: .utf8) {
            print("🎵 DEBUG: Separation job status response body: \(responseText)")
        }
        
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            print("🎵 DEBUG: HTTP error polling separation job: \(http.statusCode) - \(bodyText)")
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        
        let status = try JSONDecoder().decode(SepJobStatus.self, from: data)
        print("🎵 DEBUG: Decoded separation job status: \(status)")
        print("🎵 DEBUG: - Status: \(status.status)")
        print("🎵 DEBUG: - Instrumental URL: \(status.instrumental_url?.absoluteString ?? "nil")")
        print("🎵 DEBUG: - Vocals URL: \(status.vocals_url?.absoluteString ?? "nil")")
        return status
    }







    private static func makeMultipartBody(fileURL: URL, fieldName: String, fileName: String, mimeType: String, additionalFields: [String: String], boundary: String) throws -> Data {
        var body = Data()
        func append(_ string: String) {
            if let d = string.data(using: .utf8) { body.append(d) }
        }

        for (key, value) in additionalFields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        let fileData = try loadFileData(fileURL)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    // Simple network retry to mask brief backend restarts (Simulator  Could not connect to the server)
    private static func uploadWithRetry(session: URLSession, request: URLRequest, body: Data, retries: Int = 3) async throws -> (Data, URLResponse) {
        var attempt = 0
        var lastError: Error?
        while attempt <= retries {
            do {
                return try await session.upload(for: request, from: body)
            } catch {
                lastError = error
                attempt += 1
                if attempt > retries { break }
                // Backoff: 0.4, 0.8, 1.2s
                let delay = 0.4 * Double(attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
        }
        throw lastError ?? APIError.badResponse
    }

    // Fallback uploader that splits large files into smaller multipart chunks
    // and retries the request if the first attempt fails quickly due to network hiccups.
    static func uploadJobStartWithFallback(url: URL, endpoint: String, fields: [String:String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: endpoint))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let fileData = try loadFileData(url)
        // If file is small, normal upload
        if fileData.count < 5_000_000 { // <5MB
            let body = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: fields, boundary: boundary)
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 60.0   // 1 minute for initial connection
            cfg.timeoutIntervalForResource = 300.0 // 5 minutes total for upload
            let session = URLSession(configuration: cfg)
            return try await uploadWithRetry(session: session, request: request, body: body, retries: 2)
        }
        // For large files, build the multipart in smaller appended pieces to reduce memory spikes
        var body = Data(capacity: fileData.count + 1024)
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        for (k, v) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n")
            append("\(v)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n")
        append("Content-Type: \(mimeType(for: url))\r\n\r\n")
        let chunkSize = 1_000_000 // 1MB
        var offset = 0
        while offset < fileData.count {
            let end = min(offset + chunkSize, fileData.count)
            body.append(fileData.subdata(in: offset..<end))
            offset = end
        }
        append("\r\n--\(boundary)--\r\n")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60.0   // 1 minute for initial connection
        cfg.timeoutIntervalForResource = 300.0 // 5 minutes total for upload
        let session = URLSession(configuration: cfg)
        return try await uploadWithRetry(session: session, request: request, body: body, retries: 2)
    }

    // Final fallback: stream multipart from a temporary file using upload(fromFile:)
    static func uploadJobStartStreaming(url: URL, endpoint: String, fields: [String:String]) async throws -> (Data, URLResponse) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Config.serverBaseURL.appending(path: endpoint))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        // Create temp file for multipart
        let tmp = FileManager.default.temporaryDirectory.appending(path: "upload_\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: tmp) else {
            throw APIError.badResponse
        }
        defer { try? out.close() }
        
        func write(_ s: String) throws { if let d = s.data(using: .utf8) { try out.write(contentsOf: d) } }
        for (k, v) in fields {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n")
            try write("\(v)\r\n")
        }
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n")
        try write("Content-Type: \(mimeType(for: url))\r\n\r\n")
        
        // Stream the source file into the multipart temp
        let inNeeds = url.startAccessingSecurityScopedResource()
        if let src = try? FileHandle(forReadingFrom: url) {
            defer { try? src.close() }
            while autoreleasepool(invoking: {
                let data = try? src.read(upToCount: 1_000_000)
                if let data, !data.isEmpty { try? out.write(contentsOf: data); return true }
                return false
            }) {}
        }
        if inNeeds { url.stopAccessingSecurityScopedResource() }
        try write("\r\n--\(boundary)--\r\n")
        
        // Use reasonable timeouts to prevent hanging
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60.0  // 1 minute for initial connection
        cfg.timeoutIntervalForResource = 300.0 // 5 minutes total for upload
        cfg.waitsForConnectivity = false      // Don't wait indefinitely for connectivity
        let session = URLSession(configuration: cfg)
        
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try await session.upload(for: request, fromFile: tmp)
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    private static func loadFileData(_ url: URL) throws -> Data {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}


