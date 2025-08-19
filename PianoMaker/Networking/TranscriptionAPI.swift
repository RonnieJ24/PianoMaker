import Foundation

enum APIError: Error {
    case badResponse
    case invalidURL
    case downloadFailed
}

struct TranscriptionAPI {
    struct QueuedJob: Decodable { let status: String; let job_id: String }
    struct JobStatus: Decodable { let status: String; let progress: Double?; let wav_url: URL? }
    struct SeparationResp: Decodable { let status: String; let job_id: String; let instrumental_url: URL?; let vocals_url: URL?; let backend: String?; let fallback_from: String? }
    struct MelodyResp: Decodable { let status: String; let midi_url: URL; let wav_url: URL? }
    struct CoverHQResp: Decodable { let status: String; let midi_url: URL; let wav_url: URL? }
    struct CoverStyleResp: Decodable { let status: String; let midi_url: URL; let wav_url: URL? }
    static func uploadAudio(url: URL, useDemucs: Bool) async throws -> TranscriptionResponse {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/transcribe"))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: [
            "use_demucs": useDemucs ? "true" : "false"
        ], boundary: boundary)

        // Increase timeout for long conversions (Demucs + transcription)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1200
        config.timeoutIntervalForResource = 1200
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

    static func separateAudio(url: URL, mode: String? = nil, enhance: Bool? = nil, queued: Bool = true) async throws -> SeparationResp {
        let endpoint = queued ? "/separate_start" : "/separate"
        var fields: [String: String] = [:]
        if let mode = mode, !mode.isEmpty { fields["mode"] = mode }
        if let enhance = enhance, enhance { fields["enhance"] = "true" }
        // Use streaming multipart upload for reliability with large files and on Simulator
        let (data, response) = try await uploadJobStartStreaming(url: url, endpoint: endpoint, fields: fields)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        // If queued, poll /job/{id} until we get instrumental/vocals URLs
        if queued {
            struct Queued: Decodable { let status: String; let job_id: String }
            let queuedResp = try JSONDecoder().decode(Queued.self, from: data)
            let jobId = queuedResp.job_id
            while true {
                try await Task.sleep(nanoseconds: 900_000_000)
                let status = try await pollJob(jobId: jobId)
                if status.status == "done" || (status.instrumental_url != nil || status.vocals_url != nil) {
                    return SeparationResp(status: status.status, job_id: jobId, instrumental_url: status.instrumental_url, vocals_url: status.vocals_url, backend: status.backend, fallback_from: status.fallback_from)
                }
                if status.status == "error" {
                    throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: status.error ?? "Separation failed"])
                }
            }
        } else {
            return try JSONDecoder().decode(SeparationResp.self, from: data)
        }
    }

    static func separateAudioAPI(url: URL, spleeterOnly: Bool = false, vocalsOnly: Bool = false, localSpleeter: Bool = false) async throws -> SeparationResp {
        var fields: [String: String] = [:]
        if spleeterOnly { fields["force"] = "true" }
        if vocalsOnly { fields["target"] = "vocals" }
        if localSpleeter { fields["local"] = "true" }
        let (data, response) = try await uploadJobStartStreaming(url: url, endpoint: "/separate_api", fields: fields)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        do {
            return try JSONDecoder().decode(SeparationResp.self, from: data)
        } catch {
            let bodyText = String(data: data, encoding: .utf8) ?? "Invalid JSON"
            throw NSError(domain: "API", code: -1, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
    }

    static func uploadAudioPTI(url: URL, useDemucs: Bool) async throws -> TranscriptionResponse {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/transcribe_pti"))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: [
            "use_demucs": useDemucs ? "true" : "false"
        ], boundary: boundary)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1200
        config.timeoutIntervalForResource = 1200
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

    static func poll(jobId: String) async throws -> TranscriptionResponse {
        let url = Config.serverBaseURL.appending(path: "/status/\(jobId)")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 120
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data)
    }

    static func pollUntilDone(jobId: String, interval: TimeInterval = 1.2, maxMinutes: Double = 30) async throws -> TranscriptionResponse {
        let deadline = Date().addingTimeInterval(maxMinutes * 60)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            do {
                let status = try await poll(jobId: jobId)
                if status.status == .done { return status }
            } catch {
                // Ignore transient poll timeouts and keep polling
                continue
            }
        }
        throw NSError(domain: "API", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Polling timed out. Please try again."])
    }

    static func transcribeStart(url: URL, useDemucs: Bool, profile: String? = nil) async throws -> QueuedJob {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/transcribe_start"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields: [String: String] = [
            "use_demucs": useDemucs ? "true" : "false"
        ]
        if let p = profile, !p.isEmpty { fields["profile"] = p }
        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: fields, boundary: boundary)
        let cfg = URLSessionConfiguration.default
        // Larger timeouts to avoid upload timeouts on big files/simulator
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 600
        let session = URLSession(configuration: cfg)
        let (data, response) = try await uploadWithRetry(session: session, request: request, body: formData, retries: 3)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try JSONDecoder().decode(QueuedJob.self, from: data)
    }

    static func download(url: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }

        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appending(path: "Transcriptions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let outURL = folder.appending(path: "\(UUID().uuidString).\(ext)")
        try data.write(to: outURL)
        return outURL
    }

    static func startRenderSFZ(midiData: Data, preview: Bool = true) async throws -> String {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/render_sfizz_start"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ s: String) { if let d = s.data(using: .utf8) { body.append(d) } }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"sr\"\r\n\r\n")
        append("44100\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"preview\"\r\n\r\n")
        append(preview ? "true\r\n" : "false\r\n")
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

    static func pollRenderJob(jobId: String) async throws -> JobStatus {
        let url = Config.serverBaseURL.appending(path: "/job/\(jobId)")
        let (data, response) = try await URLSession.shared.data(from: url)
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
        let backend: String?
        let fallback_from: String?
        let error: String?
    }
    static func pollJob(jobId: String) async throws -> SepJobStatus {
        let url = Config.serverBaseURL.appending(path: "/job/\(jobId)")
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try JSONDecoder().decode(SepJobStatus.self, from: data)
    }

    static func ddspMelodyToPiano(url: URL, render: Bool = true) async throws -> MelodyResp {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/ddsp_melody_to_piano"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: ["render": render ? "true" : "false"], boundary: boundary)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 600
        let session = URLSession(configuration: cfg)
        let (data, response) = try await session.upload(for: request, from: formData)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try JSONDecoder().decode(MelodyResp.self, from: data)
    }

    static func pianoCoverHQ(url: URL, useDemucs: Bool = false, render: Bool = true) async throws -> CoverHQResp {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/piano_cover_hq"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: [
            "use_demucs": useDemucs ? "true" : "false",
            "render": render ? "true" : "false"
        ], boundary: boundary)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 1800
        cfg.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: cfg)
        let (data, response) = try await session.upload(for: request, from: formData)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try JSONDecoder().decode(CoverHQResp.self, from: data)
    }

    static func pianoCoverStyle(url: URL, style: String, useDemucs: Bool = false, render: Bool = true) async throws -> CoverStyleResp {
        var request = URLRequest(url: Config.serverBaseURL.appending(path: "/piano_cover_style"))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let formData = try makeMultipartBody(fileURL: url, fieldName: "file", fileName: url.lastPathComponent, mimeType: mimeType(for: url), additionalFields: [
            "style": style,
            "use_demucs": useDemucs ? "true" : "false",
            "render": render ? "true" : "false"
        ], boundary: boundary)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 1800
        cfg.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: cfg)
        let (data, response) = try await session.upload(for: request, from: formData)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "Server returned status \(http.statusCode)"
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: bodyText])
        }
        return try JSONDecoder().decode(CoverStyleResp.self, from: data)
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
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 600
            cfg.timeoutIntervalForResource = 600
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
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 1200
        cfg.timeoutIntervalForResource = 1200
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
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 1800
        cfg.timeoutIntervalForResource = 1800
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


