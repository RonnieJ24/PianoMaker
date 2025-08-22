import Foundation

enum Config {
    static var serverBaseURL: URL {
        // Simple, reliable configuration - just use the full backend
        return URL(string: "http://10.0.0.231:8010")!
    }
    
    static func setServerBaseURL(_ urlString: String) {
        // Keep this for manual override if needed
        UserDefaults.standard.set(urlString, forKey: "server_url")
    }
}


