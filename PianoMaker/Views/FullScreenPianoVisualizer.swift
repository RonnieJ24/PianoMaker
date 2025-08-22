import SwiftUI
import AVFoundation
import AudioToolbox

struct FullScreenPianoVisualizer: View {
    let renderedWAVURL: URL?
    let midiURL: URL?
    
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var wavPlayer: AVAudioPlayer?
    @State private var midiPlayer: MIDIPlayer?
    @State private var midiNotes: [PianoNote] = []
    @State private var activeNotes: Set<Int> = []
    @State private var displayLink: CADisplayLink?
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            backgroundView
            mainContentView
        }
        .navigationBarHidden(true)
        .onAppear {
            setupAudioPlayer()
            loadMIDINotes()
            startDisplayLink()
        }
        .onDisappear {
            stopDisplayLink()
            stopPlayback()
        }
        .onChange(of: isPlaying) { _, newValue in
            if newValue {
                startDisplayLink()
            } else {
                stopDisplayLink()
            }
        }
    }
    
    private var backgroundView: some View {
        LinearGradient(
            colors: [Color.black, Color.gray.opacity(0.3), Color.black],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
    
    private var mainContentView: some View {
        VStack(spacing: 0) {
            navigationBarView
            transportControlsView
            timeDisplayView
            pianoAndMidiView
        }
    }
    
    private var navigationBarView: some View {
        HStack {
            backButton
            Spacer()
            titleView
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.4))
    }
    
    private var backButton: some View {
        Button(action: {
            stopPlayback()
            dismiss()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Back")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color.blue, Color.cyan],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(25)
            .shadow(color: .blue.opacity(0.6), radius: 8, x: 0, y: 4)
        }
    }
    
    private var titleView: some View {
        Text("Piano Visualizer")
            .font(.title2)
            .fontWeight(.bold)
            .foregroundColor(.white)
    }
    
    private var transportControlsView: some View {
        HStack(spacing: 16) {
            playPauseButton
            stopButton
            Spacer()
            statusIndicator
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.3))
    }
    
    private var playPauseButton: some View {
        Button(action: togglePlayback) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isPlaying ?
                                [Color.orange, Color.red] :
                                [Color.blue, Color.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .shadow(color: (isPlaying ? Color.orange : Color.blue).opacity(0.8), radius: 8, x: 0, y: 4)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .fontWeight(.bold)
            }
        }
        .scaleEffect(isPlaying ? 1.1 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPlaying)
    }
    
    private var stopButton: some View {
        Button(action: stopPlayback) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.red, Color.red.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .shadow(color: Color.red.opacity(0.8), radius: 8, x: 0, y: 4)

                Image(systemName: "stop.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .fontWeight(.bold)
            }
        }
    }
    
    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isPlaying ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .scaleEffect(isPlaying ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPlaying)

            Text(isPlaying ? "PLAYING" : "STOPPED")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(isPlaying ? .green : .red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
    
    private var timeDisplayView: some View {
        VStack(spacing: 4) {
            HStack {
                Text(formatTime(currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
                
                Spacer()
                
                Text(formatTime(duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
            
            progressBarView
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
    
    private var progressBarView: some View {
        GeometryReader { progressGeometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 4)
                    .cornerRadius(2)
                
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.cyan, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: progressWidth(in: progressGeometry), height: 4)
                    .cornerRadius(2)
                    .shadow(color: .cyan, radius: 4)
            }
            .onTapGesture { value in
                let progress = value.x / progressGeometry.size.width
                let time = max(0, min(progress * duration, duration))
                seekTo(time: time)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let progress = value.location.x / progressGeometry.size.width
                        let time = max(0, min(progress * duration, duration))
                        seekTo(time: time)
                    }
            )
        }
        .frame(height: 6)
    }
    
    private var pianoAndMidiView: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            HStack(spacing: 0) {
                VerticalPianoKeyboardView(activeNotes: activeNotes, currentTime: currentTime)
                    .frame(width: 100)
                    .background(Color.black.opacity(0.9))
                
                midiGridView
            }
        }
        .background(Color.black.opacity(0.3))
    }
    
    private var midiGridView: some View {
        GeometryReader { geometry in
            ZStack {
                GridBackgroundView()
                
                ForEach(Array(midiNotes.enumerated()), id: \.offset) { index, note in
                    let isActive = currentTime >= note.start && currentTime <= (note.start + note.duration)
                    
                    let timeProgress = (currentTime - note.start + 6) / 6.0
                    let x = geometry.size.width * (1.0 - timeProgress)
                    
                    let noteIndex = 108 - note.pitch
                    let keyHeight = geometry.size.height / 88.0
                    let y = (CGFloat(noteIndex) * keyHeight) + (keyHeight / 2.0)
                    

                    
                    if x > -100 && x < geometry.size.width + 100 && y >= 0 && y <= geometry.size.height && timeProgress >= 0 && timeProgress <= 1.0 && currentTime <= note.start + note.duration + 3.0 {
                        FallingNoteView(
                            note: note,
                            isActive: isActive,
                            position: CGPoint(x: x, y: y)
                        )
                    }
                }
            }
        }
        .frame(width: 300, height: 600)
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Helper Functions
    
    private func progressWidth(in geometry: GeometryProxy) -> CGFloat {
        guard duration > 0 else { return 0 }
        return geometry.size.width * CGFloat(currentTime / duration)
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func togglePlayback() {
        print("🎵 DEBUG: Toggle playback button pressed! isPlaying: \(isPlaying)")
        if isPlaying {
            print("🎵 DEBUG: Calling pausePlayback()")
            pausePlayback()
        } else {
            print("🎵 DEBUG: Calling startPlayback()")
            startPlayback()
        }
    }
    
    private func startPlayback() {
        guard let wav = renderedWAVURL, let midi = midiURL else { 
            print("🎵 ERROR: Missing WAV or MIDI URL for playback")
            return 
        }
        
        print("🎵 DEBUG: Starting dual playback - WAV: \(wav), MIDI: \(midi)")
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            print("🎵 DEBUG: Audio session configured successfully")
            
            // Setup WAV player for audio
            print("🎵 DEBUG: Creating WAV audio player")
            wavPlayer = try AVAudioPlayer(contentsOf: wav)
            wavPlayer?.prepareToPlay()
            duration = wavPlayer?.duration ?? 0
            print("🎵 DEBUG: WAV player created - duration: \(duration)s")
            
            wavPlayer?.currentTime = 0
            currentTime = 0
            
            // Setup MIDI player for visuals (muted)
            if midiPlayer == nil {
                print("🎵 DEBUG: Creating MIDI player for visuals")
                midiPlayer = MIDIPlayer()
            }
            
            // Start both players
            let wavSuccess = wavPlayer?.play() ?? false
            
            // Load and play MIDI for visuals (muted completely)
            do {
                midiPlayer?.gainDB = -120.0 // Completely mute MIDI for visuals only
                try midiPlayer?.load(url: midi) // Load but don't play to avoid any audio
                print("🎵 DEBUG: MIDI loaded for visuals (muted)")
            } catch {
                print("🎵 WARNING: Could not load MIDI for visuals: \(error)")
            }
            
            if wavSuccess {
                isPlaying = true
                print("🎵 DEBUG: Playback started successfully")
                } else {
                print("🎵 ERROR: Failed to start WAV playback")
            }
        } catch {
            print("🎵 ERROR: Audio session setup failed: \(error)")
        }
    }
    
    private func pausePlayback() {
        wavPlayer?.pause()
        isPlaying = false
        print("🎵 DEBUG: Playback paused")
    }
    
    private func stopPlayback() {
        wavPlayer?.stop()
        wavPlayer?.currentTime = 0
        currentTime = 0
        isPlaying = false
        print("🎵 DEBUG: Playback stopped")
    }
    
    private func seekTo(time: Double) {
        wavPlayer?.currentTime = time
        currentTime = time
        print("🎵 DEBUG: Seeked to \(time)s")
    }
    
    private func setupAudioPlayer() {
        // Initialize with sample data for now
        duration = 4.18 * 60 // 4:18 in seconds
        currentTime = 0
    }
    
    private func loadMIDINotes() {
        guard let midiURL = midiURL else {
            print("🎵 ERROR: No MIDI URL provided, using sample notes")
            loadSampleNotes()
            return
        }
        
        print("🎵 Loading MIDI notes from: \(midiURL)")
        
        // Try to load actual MIDI file
        do {
            let midiData = try Data(contentsOf: midiURL)
            print("🎵 MIDI file loaded, size: \(midiData.count) bytes")
            
            // Parse MIDI file and extract notes
            let loadedNotes = try parseMIDIFile(data: midiData)
            
            if !loadedNotes.isEmpty {
                midiNotes = loadedNotes
                // Calculate duration from the last note
                if let lastNote = loadedNotes.max(by: { $0.start + $0.duration < $1.start + $1.duration }) {
                    duration = lastNote.start + lastNote.duration + 2.0 // Add 2 second buffer
                }
                print("🎵 Loaded \(loadedNotes.count) MIDI notes, duration: \(duration)s")
            } else {
                print("🎵 WARNING: No notes found in MIDI file, using sample notes")
                loadSampleNotes()
            }
        } catch {
            print("🎵 ERROR loading MIDI file: \(error), using sample notes")
            loadSampleNotes()
        }
    }
    
    private func loadSampleNotes() {
        // Create sample notes for demonstration when MIDI loading fails
        var sampleNotes: [PianoNote] = []
        
        // Create a longer sequence with repeating patterns
        for cycle in 0..<10 { // 10 cycles
            let baseTime = Double(cycle) * 8.0
            
            // Add a chord progression
            let chordNotes = [
                (60, baseTime + 0.0), (64, baseTime + 0.0), (67, baseTime + 0.0), // C major
                (62, baseTime + 1.0), (66, baseTime + 1.0), (69, baseTime + 1.0), // D minor
                (64, baseTime + 2.0), (67, baseTime + 2.0), (71, baseTime + 2.0), // E minor
                (65, baseTime + 3.0), (69, baseTime + 3.0), (72, baseTime + 3.0), // F major
                (67, baseTime + 4.0), (71, baseTime + 4.0), (74, baseTime + 4.0), // G major
                (69, baseTime + 5.0), (72, baseTime + 5.0), (76, baseTime + 5.0), // A minor
                (71, baseTime + 6.0), (74, baseTime + 6.0), (77, baseTime + 6.0), // B diminished
                (72, baseTime + 7.0), (76, baseTime + 7.0), (79, baseTime + 7.0), // C major
            ]
            
            for (pitch, start) in chordNotes {
                sampleNotes.append(PianoNote(start: start, duration: 0.8, pitch: pitch))
            }
            
            // Add melody line
            let melodyNotes = [72, 74, 76, 77, 79, 81, 83, 84]
            for (index, pitch) in melodyNotes.enumerated() {
                let start = baseTime + Double(index) * 0.5 + 0.25
                sampleNotes.append(PianoNote(start: start, duration: 0.4, pitch: pitch))
            }
        }
        
        duration = 80.0 // 80 seconds total
        midiNotes = sampleNotes
        print("🎵 Loaded \(sampleNotes.count) sample MIDI notes")
    }
    
    private func parseMIDIFile(data: Data) throws -> [PianoNote] {
        // Basic MIDI file parsing
        // This is a simplified parser - for production, you'd want a proper MIDI library
        var notes: [PianoNote] = []
        
        // Look for MIDI events in the data
        // This is a very basic implementation that looks for note on/off events
        var position = 0
        var currentTime = 0.0
        let ticksPerQuarter = 480.0 // Standard MIDI timing
        let tempo = 120.0 // BPM
        let secondsPerTick = (60.0 / tempo) / ticksPerQuarter
        
        while position < data.count - 3 {
            let byte1 = data[position]
            let byte2 = data[position + 1]
            let byte3 = data[position + 2]
            
            // Look for Note On events (0x90-0x9F)
            if (byte1 & 0xF0) == 0x90 && byte3 > 0 {
                let pitch = Int(byte2)
                let _ = Int(byte3) // velocity (not used in basic parsing)
                
                if pitch >= 21 && pitch <= 108 { // Valid piano range
                    // Look ahead for corresponding Note Off event
                    var duration = 0.5 // Default duration
                    var searchPos = position + 3
                    var searchTime = currentTime
                    
                    while searchPos < data.count - 3 {
                        let searchByte1 = data[searchPos]
                        let searchByte2 = data[searchPos + 1]
                        
                        // Note Off event (0x80-0x8F) or Note On with velocity 0
                        if ((searchByte1 & 0xF0) == 0x80 || ((searchByte1 & 0xF0) == 0x90 && data[searchPos + 2] == 0)) 
                           && searchByte2 == byte2 {
                            duration = searchTime - currentTime
                            break
                        }
                        
                        // Simple time advancement (very basic)
                        if data[searchPos] < 0x80 {
                            searchTime += Double(data[searchPos]) * secondsPerTick
                        }
                        
                        searchPos += 1
                    }
                    
                    let note = PianoNote(start: currentTime, duration: max(duration, 0.1), pitch: pitch)
                    notes.append(note)
                }
            }
            
            // Simple time advancement (very basic)
            if byte1 < 0x80 {
                currentTime += Double(byte1) * secondsPerTick
            }
            
            position += 1
        }
        
        return notes
    }
    
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        
        displayLink = CADisplayLink(target: DisplayLinkTarget(updateHandler: {
            [self] in
            updateCurrentTime()
        }), selector: #selector(DisplayLinkTarget.update))
        displayLink?.add(to: .main, forMode: .common)
        print("🎵 DEBUG: Display link started")
    }
    
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        print("🎵 DEBUG: Display link stopped")
    }
    
    private func updateCurrentTime() {
        guard let player = wavPlayer else { return }
        currentTime = player.currentTime
        updateActiveNotes()
    }
    
    private func updateActiveNotes() {
        let newActiveNotes = Set(midiNotes.compactMap { note in
            if currentTime >= note.start && currentTime <= note.start + note.duration {
                return note.pitch
            }
            return nil
        })
        
        if newActiveNotes != activeNotes {
            activeNotes = newActiveNotes
        }
    }
}

// Helper class for CADisplayLink
private class DisplayLinkTarget {
    private let updateHandler: () -> Void
    
    init(updateHandler: @escaping () -> Void) {
        self.updateHandler = updateHandler
    }
    
    @objc func update() {
        updateHandler()
    }
}

// MARK: - Supporting Views

struct GridBackgroundView: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Dark background
                Rectangle()
                    .fill(Color.black.opacity(0.8))
                
                // Subtle grid lines
                VStack(spacing: 0) {
                    ForEach(0..<20, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 1)
                        Spacer()
                    }
                }
                
                HStack(spacing: 0) {
                    ForEach(0..<10, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 1)
                        Spacer()
                    }
                }
            }
        }
    }
}

struct FallingNoteView: View {
    let note: PianoNote
    let isActive: Bool
    let position: CGPoint

    var body: some View {
        ZStack {
            // Main note bar - horizontal for right-to-left flow
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: isActive ? 
                            [Color.orange, Color.red, Color.yellow] : 
                            [Color.blue.opacity(0.7), Color.cyan.opacity(0.7)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 60, height: 12) // Much wider than tall for horizontal appearance
                .shadow(color: isActive ? .orange : .blue, radius: isActive ? 15 : 8)
                .scaleEffect(isActive ? 1.3 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isActive)
            
            // Particle trail effect
            if isActive {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.yellow.opacity(0.6))
                        .frame(width: 6, height: 6)
                        .offset(x: CGFloat(i * -15), y: CGFloat.random(in: -10...10))
                        .opacity(0.8 - Double(i) * 0.3)
                        .animation(.easeOut(duration: 0.5).delay(Double(i) * 0.1), value: isActive)
                }
            }
        }
        .position(position)
    }
}

struct VerticalPianoKeyboardView: View {
    let activeNotes: Set<Int>
    let currentTime: Double
    
    var body: some View {
        VStack(spacing: 2) {
            // Bar indicator at the bottom
            VStack(spacing: 4) {
                Text("BAR")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

                Text("\(Int(currentTime / 4.0) + 1)") // 4 beats per measure
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6))
            .cornerRadius(12)
            .padding(.bottom, 16)
            
            // Vertical Piano keys (reversed order - high to low pitch) - More compact
            VStack(spacing: 0.5) {
                ForEach((21..<109).reversed(), id: \.self) { noteNumber in  // Full piano range (A0 to C8)
                    let isBlackKey = [1, 3, 6, 8, 10].contains(noteNumber % 12)
                    let isActive = activeNotes.contains(noteNumber)
                    let noteName = getNoteLabel(for: noteNumber)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: isBlackKey ? 4 : 6)
                            .fill(
                                isBlackKey ?
                                LinearGradient(colors: [Color.black, Color.black], startPoint: .leading, endPoint: .trailing) :
                                LinearGradient(colors: [Color.white, Color.gray.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: isBlackKey ? 60 : 80, height: isBlackKey ? 12 : 16)
                            .shadow(color: isActive ? .orange.opacity(0.8) : .black.opacity(0.3), radius: isActive ? 8 : 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: isBlackKey ? 4 : 6)
                                    .stroke(isActive ? Color.orange : Color.clear, lineWidth: isActive ? 3 : 0)
                            )
                            .scaleEffect(isActive ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: isActive)
                        
                        if !isBlackKey {
                            Text(noteName)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.black.opacity(0.7))
                                .offset(x: 35, y: 0)
                        }
                    }
                }
            }
        }
        .background(Color.black.opacity(0.9))
    }
    
    private func getNoteLabel(for noteNumber: Int) -> String {
        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (noteNumber / 12) - 1
        let noteName = noteNames[noteNumber % 12]
        return "\(noteName)\(octave)"
    }
}