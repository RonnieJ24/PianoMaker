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
                serverStatusSection
                
                // Professional Mode Indicator
                if vm.transcriptionMode == "professional" {
                    professionalModeSection
                }
                

                
                // Transcription Controls
                transcriptionControlsSection
                
                // Audio Separation Section
                audioSeparationSection
                
                // Selected Audio Section
                if let url = vm.selectedFileURL {
                    selectedAudioSection(url: url)
                }
                
                // MIDI Result Section (when transcription is complete)
                if let midi = vm.midiLocalURL {
                    midiResultSection(midi: midi)
                }
                
                // Progress and Info Section
                if let msg = vm.infoMessage {
                    infoSection(message: msg)
                }
                
                if let t = vm.progressText {
                    progressSection(text: t)
                }
                
                // Recent Section
                if !vm.history.isEmpty {
                    recentSection
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
                            vm.errorMessage = nil
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .background(
            // Global Audio Player at bottom - using background to avoid toolbar interference
            VStack {
                Spacer()
                
                // Debug info
                if globalPlayer.currentURL == nil {
                    Text("Global Player: No URL set")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.bottom, 10)
                }
                
                if globalPlayer.currentURL != nil && !globalPlayer.isHidden {
                    ModernGlobalAudioPlayerView()
                        .environmentObject(globalPlayer)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // Show player button when hidden
                if globalPlayer.currentURL != nil && globalPlayer.isHidden {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            globalPlayer.isHidden = false
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundColor(.blue)
                            Text("Show Player")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                    }
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // Test button to show global player
                Button(action: {
                    // Set a test URL to make the global player visible
                    globalPlayer.play(url: URL(string: "test://audio.mp3")!)
                }) {
                    Text("Test Global Player")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .padding(.bottom, 10)
            }
        )
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                vm.selectedFileURL = url
            case .failure(let error):
                vm.errorMessage = "Failed to import file: \(error.localizedDescription)"
            }
        }
        .task {
            await vm.refreshServerStatus()
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
    
    // MARK: - View Components
    
    private var serverStatusSection: some View {
        Section("Connection Status") {
            HStack {
                Image(systemName: vm.serverReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(vm.serverReachable ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.serverReachable ? "Connected to server" : "Server unreachable")
                        .font(.body)
                    Text(Config.serverBaseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vm.serverReachable {
                    Text("Server ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var professionalModeSection: some View {
        Section("🎯 Professional Mode Active") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                    Text("Studio-Quality Output")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                
                Text("This mode provides the highest quality local processing with:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Studio-quality velocity shaping")
                            .font(.caption)
                    }
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Professional timing and expression")
                            .font(.caption)
                    }
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Rich sustain and legato handling")
                            .font(.caption)
                    }
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Musical phrase awareness")
                            .font(.caption)
                    }
                }
                .padding(.leading, 8)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color.yellow.opacity(0.1))
            .cornerRadius(8)
        }
    }
    

    
    private var transcriptionControlsSection: some View {
        Section("Transcription Controls") {
            Picker("Transcription Quality", selection: $vm.transcriptionMode) {
                Text("Pure").tag("pure")
                Text("Hybrid").tag("hybrid")
                Text("Professional").tag("professional")
                Text("AI Enhanced").tag("enhanced")
            }.pickerStyle(.segmented)
            
            Text(vm.transcriptionMode == "pure" ? "Website-style output with no post-processing" : 
                 vm.transcriptionMode == "hybrid" ? "Basic Pitch + AI enhancement (Studio-quality velocity + professional timing + rich sustain)" :
                 vm.transcriptionMode == "professional" ? "Studio-quality local processing (Best for professional output)" :
                 "Enhanced with quantization, humanization, and AI refinement")
                .font(.caption2)
                .foregroundStyle(.secondary)
            

            
            HStack {
                Button("Convert to MIDI") {
                    Task {
                        await vm.transcribeSelectedFile()
                    }
                }
                .disabled(vm.selectedFileURL == nil || vm.isUploading)
                .buttonStyle(.borderedProminent)
                
                if vm.isUploading {
                    Text("Processing...")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var audioSeparationSection: some View {
        Section("Audio Separation:") {
            Text("Separation: High Quality (Demucs)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Button("Separate Vocals/Music") {
                Task {
                    await vm.runSeparation()
                }
            }
            .disabled(vm.selectedFileURL == nil || vm.isSeparating)
            .buttonStyle(.borderedProminent)
        }
    }
    
    private func selectedAudioSection(url: URL) -> some View {
        Section("Selected audio") {
            VStack(alignment: .leading, spacing: 8) {
                Text(url.lastPathComponent).font(.headline)
                WaveformView(url: url)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original")
                    // Prevent triggering list row selection or any parent button actions
                    AudioPreview(url: url)
                        .environmentObject(globalPlayer)
                        .contentShape(Rectangle())
                        .onTapGesture { /* consume tap */ }
                }
            }
        }
    }
    
    private func midiResultSection(midi: URL) -> some View {
        Section("Result") {
            NavigationLink(destination: DetailViewWithLivePlayer(vm: vm)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MIDI ready: \(midi.lastPathComponent)")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if let noteCount = vm.notesCount, let duration = vm.durationSec {
                        Text("Notes: \(noteCount), Duration: \(String(format: "%.1fs", duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("Tap to view, play & render →")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        }
    }
    
    private func infoSection(message: String) -> some View {
        Section("Info") {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }
    
    private func progressSection(text: String) -> some View {
        Section("Progress") {
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
    
    private var recentSection: some View {
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

#Preview {
    HomeView()
}


