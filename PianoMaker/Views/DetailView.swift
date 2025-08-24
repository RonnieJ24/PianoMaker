import SwiftUI
import AVFoundation
import AudioToolbox

struct DetailView: View {
    @ObservedObject var vm: TranscriptionViewModel
    @State private var isPlaying = false
    private let player = MIDIPlayer()
    @State private var isRendering = false
    @State private var renderProgress: Double = 0
    @State private var renderedURL: URL?
    @State private var isPlayingWav = false
    @State private var wavPlayer: AVAudioPlayer?
    @State private var scrubPosition: Double = 0
    @State private var wavTimer: Timer?

    var body: some View {
        VStack(spacing: 16) {
            if let midi = vm.midiLocalURL {
                Text(midi.lastPathComponent).font(.headline)
                HStack(spacing: 12) {
                    Button(isPlaying ? "Stop" : "Play") {
                        if isPlaying {
                            player.stop()
                            isPlaying = false
                        } else {
                            do { try player.playMIDI(url: midi) } catch { }
                            isPlaying = true
                        }
                    }

                    ShareLink(item: midi) {
                        Label("Share MIDI", systemImage: "square.and.arrow.up")
                    }
                    Button("Expressive MIDI") {
                        Task {
                            if let enhanced = try? await vm.enhancePerformance(midiURL: midi) {
                                // Replace displayed MIDI with enhanced version for quick A/B
                                vm.midiLocalURL = enhanced
                            }
                        }
                    }
                    Button("Expressive (ML)") {
                        Task {
                            if let enhanced = try? await vm.enhancePerformanceML(midiURL: midi) {
                                vm.midiLocalURL = enhanced
                            }
                        }
                    }
                    
                }
                
                // SoundFont Selection for Rendering
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose SoundFont for Rendering:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Picker("SoundFont", selection: $vm.selectedSoundFont) {
                        ForEach(TranscriptionAPI.SoundFont.allCases, id: \.self) { soundFont in
                            Text(soundFont.rawValue).tag(soundFont)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    Text(vm.selectedSoundFont.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    
                    HStack(spacing: 12) {
                        Button(isRendering ? "Rendering…" : "Render with Selected SoundFont") {
                            Task {
                                isRendering = true
                                renderProgress = 0
                                defer { isRendering = false }
                                
                                do {
                                    let midiData = try Data(contentsOf: midi)
                                    print("🎵 DEBUG: Starting render with SoundFont: \(vm.selectedSoundFont.rawValue)")
                                    
                                    // For FluidSynth rendering, use the synchronous endpoint directly
                                    if vm.selectedSoundFont.type == "sf2" {
                                        renderProgress = 0.3
                                        
                                        // Call the synchronous render endpoint
                                        let renderResult = try await TranscriptionAPI.renderDirectly(midiData: midiData, soundFont: vm.selectedSoundFont)
                                        print("🎵 DEBUG: Render completed directly: \(renderResult)")
                                        
                                        renderProgress = 0.9
                                        
                                        // Download the WAV file
                                        let (wavData, wavResp) = try await URLSession.shared.data(from: renderResult.wav_url)
                                        guard let http = wavResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { 
                                            print("🎵 DEBUG: Failed to download WAV - HTTP \(wavResp)")
                                            throw NSError(domain: "API", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to download rendered WAV"])
                                        }
                                        
                                        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                                            .appending(path: "Transcriptions", directoryHint: .isDirectory)
                                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                        let outURL = folder.appending(path: "\(UUID().uuidString)_\(vm.selectedSoundFont.rawValue.replacingOccurrences(of: ".", with: "_")).wav")
                                        try wavData.write(to: outURL)
                                        renderedURL = outURL
                                        vm.lastRenderedWav = outURL // Update ViewModel for Live Piano Player
                                        renderProgress = 1.0
                                        print("🎵 DEBUG: Render completed: \(outURL.path)")
                                        
                                    } else {
                                        // For SFZ rendering, use the async endpoint
                                        let jobId = try await TranscriptionAPI.startRender(midiData: midiData, soundFont: vm.selectedSoundFont)
                                        print("🎵 DEBUG: SFZ render job started: \(jobId)")
                                        
                                        // Poll for completion
                                        var completed = false
                                        var lastProgress = 0.0
                                        
                                        for attempt in 1...60 { // Max 2 minutes
                                            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                                            
                                            do {
                                                let status = try await TranscriptionAPI.pollRenderJob(jobId: jobId)
                                                print("🎵 DEBUG: SFZ render attempt \(attempt): status=\(status.status), progress=\(status.progress ?? 0)")
                                                
                                                if let progress = status.progress, progress > lastProgress {
                                                    renderProgress = progress
                                                    lastProgress = progress
                                                }
                                                
                                                if status.status == "done", let url = status.wav_url {
                                                    renderProgress = 0.9
                                                    let (wavData, wavResp) = try await URLSession.shared.data(from: url)
                                                    guard let http = wavResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { 
                                                        print("🎵 DEBUG: Failed to download WAV - HTTP \(wavResp)")
                                                        break 
                                                    }
                                                    
                                                    let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                                                        .appending(path: "Transcriptions", directoryHint: .isDirectory)
                                                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                                    let outURL = folder.appending(path: "\(UUID().uuidString)_\(vm.selectedSoundFont.rawValue.replacingOccurrences(of: ".", with: "_")).wav")
                                                    try wavData.write(to: outURL)
                                                    renderedURL = outURL
                                                    vm.lastRenderedWav = outURL
                                                    renderProgress = 1.0
                                                    print("🎵 DEBUG: SFZ render completed: \(outURL.path)")
                                                    completed = true
                                                    break
                                                }
                                                
                                                if status.status == "error" {
                                                    print("🎵 DEBUG: SFZ render failed with error")
                                                    break
                                                }
                                                
                                                if status.status == "processing" && renderProgress < 0.8 {
                                                    renderProgress = min(renderProgress + 0.05, 0.8)
                                                }
                                            } catch {
                                                print("🎵 DEBUG: Error polling SFZ job \(jobId): \(error)")
                                                if attempt > 10 { break }
                                            }
                                        }
                                        
                                        if !completed {
                                            print("🎵 DEBUG: SFZ render timed out after 60 attempts")
                                            renderProgress = 0
                                        }
                                    }
                                } catch {
                                    print("🎵 DEBUG: Render error: \(error)")
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
                

                // Piano Visualizer Toggle Button
                VStack(spacing: 12) {
                    NavigationLink(destination: FullScreenPianoVisualizer(
                        renderedWAVURL: renderedURL,
                        midiURL: vm.midiLocalURL
                    )) {
                        HStack {
                            Image(systemName: "pianokeys")
                                .font(.title2)
                            VStack(alignment: .leading) {
                                Text("Live Piano Visualizer")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                Text("Full-screen GarageBand-style view")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.blue.opacity(0.1),
                                            Color.purple.opacity(0.1)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(
                                            LinearGradient(
                                                colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 1
                                        )
                                )
                        )
                        .foregroundColor(.primary)
                    }
                }
            }
            Spacer()
            if let wav = renderedURL {
                Text("Rendered WAV:")
                Text(wav.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                if isRendering {
                    ProgressView(value: renderProgress)
                        .frame(maxWidth: 220)
                }
                HStack(spacing: 12) {
                    Button(isPlayingWav ? "Stop WAV" : "Play WAV") {
                        if isPlayingWav {
                            wavPlayer?.stop()
                            isPlayingWav = false
                            stopWavTimer()
                        } else {
                            do {
                                let session = AVAudioSession.sharedInstance()
                                try? session.setCategory(.playback, mode: .default, options: [])
                                try? session.setActive(true)
                                wavPlayer = try AVAudioPlayer(contentsOf: wav)
                                wavPlayer?.prepareToPlay()
                                wavPlayer?.play()
                                isPlayingWav = true
                                startWavTimer()
                            } catch {
                                isPlayingWav = false
                            }
                        }
                    }
                    Button("Pause WAV") {
                        if isPlayingWav { 
                            wavPlayer?.pause() 
                            stopWavTimer()
                        }
                    }
                    Button("Reset WAV") {
                        wavPlayer?.stop()
                        wavPlayer?.currentTime = 0
                        isPlayingWav = false
                        stopWavTimer()
                    }
                    ShareLink(item: wav) {
                        Label("Share WAV", systemImage: "square.and.arrow.up")
                    }

                }
                // WAV scrubber
                if let p = wavPlayer {
                    Slider(value: Binding(get: {
                        p.currentTime
                    }, set: { v in
                        p.currentTime = max(0, min(v, p.duration))
                        if isPlayingWav && !(p.isPlaying) { p.play() }
                    }), in: 0...(wavPlayer?.duration ?? 1.0))
                    .padding(.vertical, 8)
                }
            }
            // Scrubber for MIDI
            if player.isLoaded {
                VStack {
                    Slider(value: Binding(get: {
                        player.currentTime()
                    }, set: { v in
                        player.seek(to: v)
                    }), in: 0...(player.duration()))
                    .padding(.vertical, 8)
                }
            }
        }
        .padding()
        .navigationTitle("Result")
        .onDisappear {
            player.stop()
            isPlaying = false
            wavPlayer?.stop()
            isPlayingWav = false
            stopWavTimer()
        }
    }
    
    // MARK: - Timer Management
    
    private func startWavTimer() {
        stopWavTimer()
        wavTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            // Timer will trigger UI updates for the MiniPianoPlayer
        }
    }
    
    private func stopWavTimer() {
        wavTimer?.invalidate()
        wavTimer = nil
    }
}

#Preview {
    DetailView(vm: TranscriptionViewModel())
}
