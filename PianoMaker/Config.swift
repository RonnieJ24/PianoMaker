import Foundation

enum Config {
    static var serverBaseURL: URL {
        if let s = UserDefaults.standard.string(forKey: "server_url"), let u = URL(string: s) {
            return u
        }
        return URL(string: "http://127.0.0.1:8000")!
    }
    static func setServerBaseURL(_ urlString: String) {
        UserDefaults.standard.set(urlString, forKey: "server_url")
    }

    // Try to discover a locally running backend and persist it so the user
    // does not need to manually select a port. Preference order:
    // 1) Full backend on 8010, 2) Full backend legacy on 8001, 3) Local lightweight on 8000
    static func discoverAndSetServerBaseURL() async {
        let candidates = [
            "http://127.0.0.1:8010",
            "http://127.0.0.1:8001",
            "http://127.0.0.1:8000",
        ]
        // If a value is already set, we still honor the preference order.
        // If a more preferred candidate (e.g. 8010) is healthy, switch to it.
        // Otherwise keep the existing one if it's healthy.
        var healthyExisting: URL? = nil
        if let existing = UserDefaults.standard.string(forKey: "server_url"), let u = URL(string: existing) {
            if await isHealthy(baseURL: u) {
                healthyExisting = u
            }
        }
        for s in candidates {
            guard let u = URL(string: s) else { continue }
            if await isHealthy(baseURL: u) {
                if healthyExisting == nil || healthyExisting?.absoluteString != s {
                    setServerBaseURL(s)
                }
                return
            }
        }
        // If none responded, but an existing healthy value was found, keep it
        if let e = healthyExisting {
            setServerBaseURL(e.absoluteString)
            return
        }
        // Otherwise leave the default (8000) in place
    }

    private static func isHealthy(baseURL: URL) async -> Bool {
        // Probe /health first; accept any 200 OK. Fallback to /ping.
        let health = baseURL.appending(path: "/health")
        if await quickHeadOrGetOK(url: health) { return true }
        let ping = baseURL.appending(path: "/ping")
        if await quickHeadOrGetOK(url: ping) { return true }
        return false
    }

    private static func quickHeadOrGetOK(url: URL) async -> Bool {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.0
        cfg.timeoutIntervalForResource = 1.0
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        // Try HEAD first
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return true }
        } catch { /* fall through to GET */ }
        // Try GET
        do {
            let (_, resp) = try await session.data(from: url)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return true }
        } catch { return false }
        return false
    }
}


