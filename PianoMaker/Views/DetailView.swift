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
                    Button(isRendering ? "Rendering…" : "Render Audio") {
                        Task {
                            isRendering = true
                            defer { isRendering = false }
                            if let wav = try? await vm.renderAudio(from: midi) {
                                renderedURL = wav
                            }
                        }
                    }
                    Button(isRendering ? "Rendering…" : "Render (SFZ)") {
                        Task {
                            isRendering = true
                            renderProgress = 0
                            defer { isRendering = false }
                            do {
                                let midiData = try Data(contentsOf: midi)
                                let jobId = try await TranscriptionAPI.startRenderSFZ(midiData: midiData)
                                while true {
                                    try await Task.sleep(nanoseconds: 900_000_000)
                                    let status = try await TranscriptionAPI.pollRenderJob(jobId: jobId)
                                    renderProgress = status.progress ?? renderProgress
                                    if status.status == "done", let url = status.wav_url {
                                        let (wavData, wavResp) = try await URLSession.shared.data(from: url)
                                        guard let http = wavResp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { break }
                                        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                                            .appending(path: "Transcriptions", directoryHint: .isDirectory)
                                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                        let outURL = folder.appending(path: "\(UUID().uuidString)_sfz.wav")
                                        try wavData.write(to: outURL)
                                        renderedURL = outURL
                                        renderProgress = 1.0
                                        break
                                    }
                                    if status.status == "error" { break }
                                }
                            } catch {
                                // ignore
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



