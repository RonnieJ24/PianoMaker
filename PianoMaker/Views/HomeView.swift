import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @StateObject private var vm = TranscriptionViewModel()
    @StateObject private var globalPlayer = GlobalAudioPlayerModel()
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section("Selected audio") {
                    if let url = vm.selectedFileURL {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(url.lastPathComponent).font(.headline)
                            WaveformView(url: url)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Original")
                                // Prevent triggering list row selection or any parent button actions
                                AudioPreview(url: url)
                                    .environmentObject(globalPlayer)
                                    .contentShape(Rectangle())
                                    .onTapGesture { /* consume taps */ }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("Use PTI (higher quality)", isOn: $vm.usePTI)
                                Picker("Quality", selection: $vm.profile) {
                                    Text("Fast").tag("fast")
                                    Text("Balanced").tag("balanced")
                                    Text("Accurate").tag("accurate")
                                }.pickerStyle(.segmented)
                                HStack {
                                    Toggle("Remove vocals (Demucs)", isOn: $vm.useDemucs)
                                    Spacer()
                                    Button(vm.isUploading ? "Processing…" : (vm.usePTI ? "Transcribe (PTI)" : "Convert")) {
                                        vm.startTranscription()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(vm.isUploading)
                                    Button("Stop") { vm.cancelCurrentWork() }
                                    .disabled(!(vm.isUploading || vm.isSeparating))
                                }
                                HStack(spacing: 12) {
                                    Menu {
                                        Button("Robust (Auto/HQ)") {
                                            vm.startSeparation(fast: false)
                                        }
                                        Button("Fast (Local)") {
                                            vm.startSeparation(fast: true)
                                        }
                                        Button("Great (HQ + Enhance)") {
                                            // Calls server with mode=great&enhance=true implicitly via default path
                                            Task { await vm.runSeparation(fast: false) }
                                            vm.infoMessage = "Running HQ separation with enhancement…"
                                        }
                                        Divider()
                                        Button("Hosted Spleeter (API)") {
                                            vm.startSeparation(viaAPI: true)
                                        }
                                        Button("Hosted Spleeter – Vocals only") {
                                            vm.startSeparation(viaAPI: true, vocalsOnly: true)
                                        }
                                        Button("Local Spleeter (CLI)") {
                                            vm.startSeparation(viaAPI: true, localSpleeter: true)
                                        }
                                    } label: {
                                        Label("Separate Vocals/Music", systemImage: "wand.and.stars")
                                    }
                                    .disabled(vm.selectedFileURL == nil || vm.isSeparating)
                                    if let backend = vm.separationBackend {
                                        Text("Backend: \(backend.replacingOccurrences(of: "_", with: " "))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                HStack(spacing: 12) {
                                    Button("Melody → Piano (DDSP-style)") {
                                        Task { await vm.ddspMelodyToPiano() }
                                    }
                                    .buttonStyle(.bordered)
                                    Button("Cover (HQ chords)") {
                                        Task { await vm.coverHQ() }
                                    }
                                    .buttonStyle(.bordered)
                                    Menu {
                                        Picker("Style", selection: $vm.coverStyle) {
                                            Text("Block chords").tag("block")
                                            Text("Arpeggio").tag("arpeggio")
                                            Text("Alberti").tag("alberti")
                                        }
                                        Button("Generate cover in selected style") {
                                            Task { await vm.coverStyleRun() }
                                        }
                                    } label: {
                                        Label("Cover (style)", systemImage: "pianokeys")
                                    }
                                }
                                if let msg = vm.infoMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
                                if let t = vm.progressText { Text(t).font(.caption).foregroundStyle(.secondary) }
                                if vm.usePTI {
                                    Text("Demucs is ignored when PTI is enabled.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text("No file selected")
                    }
                }

                if let midi = vm.midiLocalURL {
                    Section("Result") {
                        NavigationLink(destination: DetailView(vm: vm)) {
                            VStack(alignment: .leading) {
                                Text("MIDI ready: \(midi.lastPathComponent)")
                                if let notes = vm.notesCount, let dur = vm.durationSec {
                                    Text("Notes: \(notes), Duration: \(String(format: "%.1f", dur))s").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if vm.instrumentalURL != nil || vm.vocalsURL != nil {
                    Section("Separated tracks") {
                        if let i = vm.instrumentalURL {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Instrumental")
                                AudioPreview(url: i)
                                    .environmentObject(globalPlayer)
                                HStack {
                                    Button("Use instrumental for transcription") {
                                        vm.setSelectedFile(i)
                                    }
                                    Button("Convert instrumental → MIDI") {
                                        Task { await vm.convertInstrumentalToMIDI() }
                                    }
                                }
                            }
                        }
                        if let v = vm.vocalsURL {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Vocals")
                                AudioPreview(url: v)
                                    .environmentObject(globalPlayer)
                                HStack {
                                    Button("Use vocals for transcription") {
                                        vm.setSelectedFile(v)
                                    }
                                    Button("Convert vocals → MIDI") {
                                        Task { await vm.convertVocalsToMIDI() }
                                    }
                                }
                            }
                        }
                    }
                }

                if !vm.history.isEmpty {
                    Section("Recent") {
                        ForEach(vm.history) { item in
                            VStack(alignment: .leading) {
                                Text(item.sourceFileName)
                                Text(item.midiLocalURL.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("PianoMaker")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Select Audio") { showImporter = true }
                        Button("Use Local Server (127.0.0.1:8000)") {
                            Config.setServerBaseURL("http://127.0.0.1:8000")
                        }
                        Button("Use Full Server (127.0.0.1:8010)") {
                            Config.setServerBaseURL("http://127.0.0.1:8010")
                        }
                        Button("Use LAN Server…") {
                            // Prompt via alert
                            let alert = UIAlertController(title: "Server URL", message: "Enter http://<IP>:8000", preferredStyle: .alert)
                            alert.addTextField { tf in tf.text = UserDefaults.standard.string(forKey: "server_url") ?? "http://" }
                            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                            alert.addAction(UIAlertAction(title: "Set", style: .default, handler: { _ in
                                if let t = alert.textFields?.first?.text, !t.isEmpty { Config.setServerBaseURL(t) }
                            }))
                            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.rootViewController?.present(alert, animated: true)
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if vm.isUploading || vm.isSeparating {
                        VStack(spacing: 8) {
                            ProgressView()
                            if let t = vm.progressText { Text(t).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    GlobalAudioPlayerView()
                        .environmentObject(globalPlayer)
                        .opacity(globalPlayer.currentURL == nil ? 0 : 1)
                }
                .padding(.bottom, 8)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let first = urls.first {
                    vm.setSelectedFile(first)
                }
            case .failure:
                break
            }
        }
        .alert("Error", isPresented: Binding<Bool>(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "Unknown error")
        }
    }
}

#Preview { HomeView() }


