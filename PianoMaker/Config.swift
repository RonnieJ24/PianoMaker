import Foundation

enum Config {
    static var serverBaseURL: URL {
        // 1) Honor manual override if present
        if let override = UserDefaults.standard.string(forKey: "server_url"),
           let url = URL(string: override), !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return url
        }
        // 2) Default: Simulator uses localhost; device uses LAN IP if set
        #if targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:8010")!
        #else
        // If you run on a physical device, replace with your Mac's LAN IP
        // Or set at runtime via the app's ⋯ menu which saves to UserDefaults("server_url")
        return URL(string: "http://10.0.0.231:8010")!
        #endif
    }
    
    static func setServerBaseURL(_ urlString: String) {
        UserDefaults.standard.set(urlString, forKey: "server_url")
    }
}


