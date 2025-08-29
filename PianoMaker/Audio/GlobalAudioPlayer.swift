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
    @Published var isHidden: Bool = false

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



struct ModernGlobalAudioPlayerView: View {
    @EnvironmentObject var model: GlobalAudioPlayerModel
    @State private var isExpanded = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Main player bar
            HStack(spacing: 16) {
                // Play/Pause button with modern design
                Button(action: {
                    model.isPlaying ? model.pause() : model.resume()
                }) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            LinearGradient(
                                colors: model.isPlaying ? 
                                    [Color.orange, Color.red] : 
                                    [Color.blue, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                }
                
                // Track info
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Text("\(format(model.currentTime)) / \(format(model.duration))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                
                Spacer()
                
                // Control buttons
                HStack(spacing: 12) {
                    // Stop button
                    Button(action: { model.stop() }) {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                            .foregroundColor(.red)
                            .frame(width: 32, height: 32)
                            .background(Color.red.opacity(0.1))
                            .clipShape(Circle())
                    }
                    
                    // Expand/Collapse button
                    Button(action: { 
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                            .font(.title3)
                            .foregroundColor(.primary)
                            .frame(width: 32, height: 32)
                            .background(Color.primary.opacity(0.1))
                            .clipShape(Circle())
                    }
                    
                    // Hide button
                    Button(action: { 
                        withAnimation(.easeInOut(duration: 0.3)) {
                            model.isHidden = true
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(.red)
                            .frame(width: 32, height: 32)
                            .background(Color.red.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            
            // Expanded section with progress bar
            if isExpanded {
                VStack(spacing: 16) {
                    // Progress bar
                    VStack(spacing: 8) {
                        HStack {
                            Text(format(model.currentTime))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                            
                            Spacer()
                            
                            Text(format(model.duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        
                        // Custom progress slider
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                // Background track
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 8)
                                
                                // Progress bar
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.blue, Color.cyan],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(
                                        width: progressWidth(in: geometry),
                                        height: 8
                                    )
                                    .shadow(color: .cyan.opacity(0.5), radius: 2)
                                
                                // Draggable handle
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 20, height: 20)
                                    .shadow(color: .black.opacity(0.3), radius: 3)
                                    .position(x: progressWidth(in: geometry) - 10, y: 4)
                            }
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let progress = value.location.x / geometry.size.width
                                        let time = max(0, min(progress * model.duration, model.duration))
                                        model.seek(to: time)
                                    }
                            )
                        }
                        .frame(height: 20)
                    }
                    
                    // Debug info (if available)
                    if !model.debugText.isEmpty {
                        Text(model.debugText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }
    
    private func progressWidth(in geometry: GeometryProxy) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return (model.currentTime / model.duration) * geometry.size.width
    }
    
    func format(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}


