import SwiftUI
import AVFoundation

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
                    Button("Download MIDI") {
                        Task {
                            if let midiURL = vm.midiURL {
                                await vm.downloadMIDIFile(from: midiURL, originalFilename: vm.selectedFileURL?.lastPathComponent ?? "song.mid")
                            }
                        }
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
                                    
                                    // Use the correct rendering method based on SoundFont type
                                    let jobId = try await TranscriptionAPI.startRender(midiData: midiData, soundFont: vm.selectedSoundFont)
                                    print("🎵 DEBUG: Render job started: \(jobId)")
                                    
                                    // Poll for completion with better error handling
                                    var completed = false
                                    for attempt in 1...60 { // Max 2 minutes
                                        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                                        
                                        do {
                                            let status = try await TranscriptionAPI.pollRenderJob(jobId: jobId)
                                            print("🎵 DEBUG: Render attempt \(attempt): status=\(status.status), progress=\(status.progress ?? 0)")
                                            renderProgress = status.progress ?? renderProgress
                                            
                                            if status.status == "done", let url = status.wav_url {
                                                print("🎵 DEBUG: Render completed, downloading WAV...")
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
                                                renderProgress = 1.0
                                                print("🎵 DEBUG: Render completed: \(outURL.path)")
                                                completed = true
                                                break
                                            }
                                            
                                            if status.status == "error" {
                                                print("🎵 DEBUG: Render failed with error")
                                                break
                                            }
                                        } catch {
                                            print("🎵 DEBUG: Error polling job \(jobId): \(error)")
                                            // Continue trying for a few more attempts
                                            if attempt > 10 {
                                                break
                                            }
                                        }
                                    }
                                    
                                    if !completed {
                                        print("🎵 DEBUG: Render timed out or failed after 60 attempts")
                                    }
                                } catch {
                                    print("🎵 DEBUG: Render error: \(error)")
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
                
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu("Sound") {
                            Button("Roomy (more reverb)") {
                                // reverb mix adjustment via Notification or simple default update in player could be added later
                            }
                            Button("Dry (less reverb)") {
                                // placeholder; keeping UI simple for now
                            }
                        }
                    }
                }
                PianoRollView(midiURL: midi)
                    .frame(height: 200)
                    .padding(.top, 8)
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
                        } else {
                            do {
                                let session = AVAudioSession.sharedInstance()
                                try? session.setCategory(.playback, mode: .default, options: [])
                                try? session.setActive(true)
                                wavPlayer = try AVAudioPlayer(contentsOf: wav)
                                wavPlayer?.prepareToPlay()
                                wavPlayer?.play()
                                isPlayingWav = true
                            } catch {
                                isPlayingWav = false
                            }
                        }
                    }
                    Button("Pause WAV") {
                        if isPlayingWav { wavPlayer?.pause() }
                    }
                    Button("Reset WAV") {
                        wavPlayer?.stop(); wavPlayer?.currentTime = 0; isPlayingWav = false
                    }
                    ShareLink(item: wav) {
                        Label("Share WAV", systemImage: "square.and.arrow.up")
                    }
                    Button("Download WAV") {
                        Task {
                            await vm.downloadWAVFile(from: wav, originalFilename: vm.selectedFileURL?.lastPathComponent ?? "song.wav")
                        }
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
        }
    }
}

#Preview {
    DetailView(vm: TranscriptionViewModel())
}



