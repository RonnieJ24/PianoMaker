import SwiftUI
import AVFoundation

extension Notification.Name {
    static let stopAllPreviews = Notification.Name("StopAllPreviews")
}

struct AudioPreview: View {
    let url: URL
    @EnvironmentObject var globalPlayer: GlobalAudioPlayerModel
    @State private var resolvedURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            Button((resolvedURL != nil && globalPlayer.currentURL == resolvedURL && globalPlayer.isPlaying) ? "Pause" : "Play") {
                // If this preview is currently playing via the global player, pause it; otherwise resolve and play via global player
                if let cur = resolvedURL, globalPlayer.currentURL == cur, globalPlayer.isPlaying {
                    globalPlayer.pause()
                } else {
                    // Resolve security-scoped or temp file once and cache local copy if needed
                    let session = AVAudioSession.sharedInstance()
                    try? session.setCategory(.playback, mode: .default, options: [])
                    try? session.setActive(true)
                    let needsAccess = url.startAccessingSecurityScopedResource()
                    defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
                    var local = url
                    do {
                        if url.isFileURL {
                            // Copy to Documents/Previews to avoid iOS purging temp files
                            let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                                .appending(path: "Previews", directoryHint: .isDirectory)
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
                            let dst = folder.appending(path: "\(UUID().uuidString).\(ext)")
                            let data = try Data(contentsOf: url)
                            try data.write(to: dst)
                            local = dst
                        }
                    } catch {
                        local = url
                    }
                    resolvedURL = local
                    globalPlayer.play(url: local)
                }
            }
            .buttonStyle(.plain)
            Button("Stop") {
                globalPlayer.stop()
            }
            .buttonStyle(.plain)
            // Debug: show resolved path tail and seconds (helps verify actual file used)
            Text(((resolvedURL ?? url).lastPathComponent))
                .lineLimit(1).font(.caption).foregroundStyle(.secondary)
        }
    }
}





