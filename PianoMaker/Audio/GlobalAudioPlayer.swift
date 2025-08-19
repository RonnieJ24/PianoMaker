import Foundation
import SwiftUI
import AVFoundation

final class GlobalAudioPlayerModel: ObservableObject {
    @Published var currentURL: URL?
    @Published var title: String = ""
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var debugText: String = ""
    @Published var isCollapsed: Bool = false

    private var player: AVAudioPlayer?
    private var updateTimer: Timer?

    func play(url: URL) {
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        // Create a stable local copy if needed (documents/Previews)
        var localURL = url
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            if url.isFileURL {
                let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appending(path: "Previews", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
                let dst = folder.appending(path: "\(UUID().uuidString).\(ext)")
                let data = try Data(contentsOf: url)
                try data.write(to: dst)
                localURL = dst
            }
        } catch {
            // Fall back to original URL if copy fails
            localURL = url
        }

        do {
            player = try AVAudioPlayer(contentsOf: localURL)
            player?.prepareToPlay()
            currentURL = localURL
            title = localURL.lastPathComponent
            duration = player?.duration ?? 0
            debugText = "Playing: \(localURL.path) | duration: \(String(format: "%.2f", duration))s"
            player?.play()
            isPlaying = true
            startTimer()
        } catch {
            debugText = "Failed to start player: \(error.localizedDescription)"
            isPlaying = false
        }
    }

    func pause() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
    }

    func resume() {
        guard !isPlaying else { return }
        player?.play()
        isPlaying = true
    }

    func stop() {
        updateTimer?.invalidate(); updateTimer = nil
        player?.stop(); player = nil
        isPlaying = false
        currentTime = 0
    }

    func seek(to time: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration))
        currentTime = p.currentTime
    }

    private func startTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.player else { return }
            self.currentTime = p.currentTime
        }
    }
}

struct GlobalAudioPlayerView: View {
    @EnvironmentObject var model: GlobalAudioPlayerModel

    var body: some View {
        Group {
            if model.isCollapsed {
                HStack(spacing: 8) {
                    Button(model.isPlaying ? "Pause" : "Play") {
                        model.isPlaying ? model.pause() : model.resume()
                    }
                    Text(model.title).lineLimit(1).font(.footnote)
                    Spacer()
                    Text("\(format(model.currentTime)) / \(format(model.duration))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Expand") { model.isCollapsed = false }
                }
                .padding(8)
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Button(model.isPlaying ? "Pause" : "Play") {
                            model.isPlaying ? model.pause() : model.resume()
                        }
                        Button("Stop") { model.stop() }
                        Text(model.title).lineLimit(1)
                        Spacer()
                        Text("\(format(model.currentTime)) / \(format(model.duration))")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Hide") { model.isCollapsed = true }
                    }
                    Slider(value: Binding(get: {
                        model.duration > 0 ? model.currentTime / model.duration : 0
                    }, set: { v in
                        model.seek(to: v * (model.duration > 0 ? model.duration : 0))
                    }))
                    if !model.debugText.isEmpty {
                        Text(model.debugText).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}


