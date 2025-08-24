import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @StateObject private var vm = TranscriptionViewModel()
    @StateObject private var globalPlayer = GlobalAudioPlayerModel()
    @State private var showImporter = false
    @State private var showErrorDetails = false

    var body: some View {
        NavigationStack {
            List {
                // Network and Server Status Section
                Section("Connection Status") {
                    HStack {
                        Image(systemName: vm.serverReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(vm.serverReachable ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.serverReachable ? "Server Connected" : "Server Unreachable")
                                .font(.headline)
                            Text("Network: \(vm.networkStatus)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh") {
                            Task { await vm.refreshServerStatus() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.isUploading || vm.isSeparating)
                    }
                    
                    if let errorMsg = vm.errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Error")
                                    .font(.headline)
                                Spacer()
                                Button("Clear") {
                                    vm.clearErrors()
                                }
                                .buttonStyle(.bordered)
                                Button("Details") {
                                    showErrorDetails = true
                                }
                                .buttonStyle(.bordered)
                            }
                            Text(errorMsg)
                                .font(.body)
                                .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    }
                }

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
            Text("Transcription Mode:")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Picker("Transcription Quality", selection: $vm.transcriptionMode) {
                Text("Pure Basic Pitch").tag("pure")
                Text("Hybrid").tag("hybrid")
                Text("AI Enhanced").tag("enhanced")
            }.pickerStyle(.segmented)
            
            Text(vm.transcriptionMode == "pure" ? "Website-style output with no post-processing" : 
                 vm.transcriptionMode == "hybrid" ? "Basic Pitch + AI enhancement (MUCH SHARPER + light cleanup + chord filling)" :
                 "Enhanced with quantization, humanization, and AI refinement")
                .font(.caption2)
                .foregroundStyle(.secondary)
                                
                                HStack {
                                    Spacer()
                                    Button(vm.isUploading ? "Processing…" : "Convert to MIDI") {
                                        vm.startTranscription()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(vm.isUploading || !vm.serverReachable)
                                    Button("Stop") { vm.cancelCurrentWork() }
                                    .disabled(!(vm.isUploading || vm.isSeparating))
                                }
                                VStack(spacing: 8) {
                                    HStack {
                                        Text("Audio Separation:")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Separation: High Quality (Demucs)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    HStack(spacing: 12) {
                                        Button(vm.isSeparating ? "Separating..." : "Separate Vocals/Music") {
                                            vm.startSeparation()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(vm.selectedFileURL == nil || vm.isSeparating || !vm.serverReachable)
                                        
                                        if vm.isSeparating {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        }
                                        
                                        if let backend = vm.separationBackend {
                                            Text("Using: \(backend.replacingOccurrences(of: "_", with: " "))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    
                                    // Show separation success message
                                    if vm.instrumentalURL != nil || vm.vocalsURL != nil {
                                        HStack {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                            Text("Separation completed! Both vocal and instrumental tracks are ready.")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                            Spacer()
                                        }
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 8)
                                        .background(Color.green.opacity(0.1))
                                        .cornerRadius(6)
                                    }
                                    
                                    // Show separation source info
                                    if let source = vm.separationSource {
                                        HStack {
                                            Image(systemName: source.contains("cloud") ? "cloud.fill" : "cpu")
                                                .foregroundColor(source.contains("cloud") ? .blue : .green)
                                            Text("Processing: \(source.replacingOccurrences(of: "_", with: " "))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                    }
                                    
                                    if let cloudModel = vm.separationCloudModel {
                                        HStack {
                                            Image(systemName: "cpu.fill")
                                                .foregroundColor(.blue)
                                            Text("Model: \(cloudModel)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                    }
                                }

                                if let msg = vm.infoMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
                                if let t = vm.progressText { Text(t).font(.caption).foregroundStyle(.secondary) }

                            }
                        }
                    } else {
                        Text("No file selected")
                    }
                }

                if let midi = vm.midiLocalURL {
                    Section("Result") {
                        NavigationLink(destination: DetailViewWithLivePlayer(vm: vm)) {
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
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Separation completed successfully!")
                                .font(.headline)
                                .foregroundColor(.green)
                            
                            // Debug info
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Debug Info:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("instrumentalURL: \(vm.instrumentalURL?.absoluteString ?? "nil")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("vocalsURL: \(vm.vocalsURL?.absoluteString ?? "nil")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(4)
                            
                            if let i = vm.instrumentalURL {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "music.note.list")
                                            .foregroundColor(.blue)
                                        Text("Instrumental (Music without vocals)")
                                            .font(.headline)
                                    }
                                    AudioPreview(url: i)
                                        .environmentObject(globalPlayer)
                                    HStack {
                                        Button("Use instrumental for transcription") {
                                            vm.setSelectedFile(i)
                                        }
                                        .buttonStyle(.bordered)
                                        Button("Convert instrumental → MIDI") {
                                            Task { await vm.convertInstrumentalToMIDI() }
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                            }
                            
                            if let v = vm.vocalsURL {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "person.wave.2")
                                            .foregroundColor(.purple)
                                        Text("Vocals (Voice only)")
                                            .font(.headline)
                                    }
                                    AudioPreview(url: v)
                                        .environmentObject(globalPlayer)
                                    HStack {
                                        Button("Use vocals for transcription") {
                                            vm.setSelectedFile(v)
                                        }
                                        .buttonStyle(.bordered)
                                        Button("Convert vocals → MIDI") {
                                            Task { await vm.convertVocalsToMIDI() }
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(Color.purple.opacity(0.1))
                                .cornerRadius(8)
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
                        Button("Refresh Server Status") {
                            Task { await vm.refreshServerStatus() }
                        }
                        Button("Clear Errors") {
                            vm.clearErrors()
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
            // Show current backend at a glance for debugging
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("Server: \(UserDefaults.standard.string(forKey: "server_url") ?? Config.serverBaseURL.absoluteString)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
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
        .sheet(isPresented: $showErrorDetails) {
            ErrorDetailsView(errorDetails: vm.lastErrorDetails ?? "No detailed error information available")
        }
    }
}

struct ErrorDetailsView: View {
    let errorDetails: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Error Details")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("This information can help debug connection issues:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text(errorDetails)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Common Issues:")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Server not running")
                            Text("• Wrong IP address or port")
                            Text("• Firewall blocking connection")
                            Text("• Network configuration issues")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Error Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview { HomeView() }


