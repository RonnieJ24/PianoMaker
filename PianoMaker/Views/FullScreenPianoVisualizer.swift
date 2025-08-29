import SwiftUI
import AVFoundation
import AudioToolbox
import AudioToolbox.MusicPlayer

// MARK: - MIDI Event Structures
// Use ExtendedTempoEvent from AudioToolbox; do not redefine it

struct FullScreenPianoVisualizer: View {
    // MARK: - Constants for Perfect Alignment
    static let pianoKeyHeight: CGFloat = 12.0
    static let totalPianoKeys: Int = 88
    static let pianoRangeStart: Int = 21  // A0
    static let pianoRangeEnd: Int = 108   // C8
    static let totalPianoHeight: CGFloat = CGFloat(totalPianoKeys) * pianoKeyHeight // 1056px
    
    // MARK: - Performance Constants
    static let visibleTimeWindow: Double = 8.0 // Show 8 seconds of notes for smooth scrolling
    static let maxRenderedNotes: Int = 500 // Limit rendered notes for performance
    static let pixelsPerSecond: CGFloat = 200.0 // Base pixels per second for time mapping (clearer widths)
    
    let renderedWAVURL: URL?
    let midiURL: URL?
    
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var wavPlayer: AVAudioPlayer?
    @State private var midiPlayer: MIDIPlayer?
    @State private var midiNotes: [PianoNote] = []
    @State private var activeNotes: Set<Int> = []
    @State private var onsetNotes: Set<Int> = []
    @State private var wallGlowExpiryByPitch: [Int: CFTimeInterval] = [:]
    @State private var displayLink: CADisplayLink?
    @State private var timeZoom: CGFloat = 1.0
    @State private var baseTimeZoom: CGFloat = 1.0
    @State private var isZoomedIn = false
    @State private var isLoadingMIDI = true
    @State private var scrollOffset: CGFloat = 0
    @State private var performanceMetrics = PerformanceMetrics()
    @State private var playbackSpeed: Float = 1.0
    @State private var pianoOffset: CGSize = .zero
    @State private var pianoScale: CGFloat = 1.0
    @State private var lastPanOffset: CGSize = .zero // Track last pan position
    @State private var isPanning = false // Track if currently panning
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            backgroundView
            pianoAndMidiView
        }
        .overlay(compactControlsView, alignment: .bottom)
        .navigationBarHidden(true)
        .onAppear {
            print("🎵 FullScreenPianoVisualizer appeared")
            setupAudioPlayer()
            loadMIDINotes()
            startDisplayLink()
            
            // Ensure initial playback speed is set
            updatePlaybackSpeed()
        }
        .onDisappear {
            stopDisplayLink()
            stopPlayback()
            
            // Reset playback speed when leaving
            playbackSpeed = 1.0
            updatePlaybackSpeed()
        }
        .onChange(of: isPlaying) { _, newValue in
            if newValue {
                startDisplayLink()
                // Ensure playback speed is maintained when resuming
                updatePlaybackSpeed()
            } else {
                stopDisplayLink()
            }
        }
                        .onChange(of: playbackSpeed) { _, newValue in
                    // Update the visual speed indicator in real-time
                    print("🎵 Playback speed changed to: \(newValue)x")
                    
                    // Ensure the speed is applied to both players immediately
                    DispatchQueue.main.async {
                        updatePlaybackSpeed()
                    }
                }

    }

    private var compactControlsView: some View {
        VStack(spacing: 0) {
            // Top bar with back button
            HStack {
                Button(action: { dismiss() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                            .foregroundColor(.white)
                        Text("Back")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(20)
                }
                
                Spacer()
                
                // Time stamp display
                Text(timeString(from: currentTime))
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .monospacedDigit()
                
                Spacer()
                
                // Speed indicator
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("\(Int(playbackSpeed * 100))%")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.4))
                .cornerRadius(12)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.3))
            
            // Time bar with dragging
            timeBarView
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            
            // Transport controls
            HStack(spacing: 16) {
                // Play/Pause button
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(
                            LinearGradient(
                                colors: isPlaying ? [Color.orange, Color.red] : [Color.blue, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                }
                
                // Stop button
                Button(action: stopPlayback) {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.red.opacity(0.8))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                // Compact speed control
                HStack(spacing: 8) {
                    Button(action: decreaseSpeed) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                    }
                    .disabled(playbackSpeed <= 0.25)
                    
                    Text("\(Int(playbackSpeed * 100))%")
                        .font(.caption)
                        .foregroundColor(.white)
                        .frame(width: 35)
                        .monospacedDigit()
                    
                    Button(action: increaseSpeed) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                    }
                    .disabled(playbackSpeed >= 4.0)
                    
                    Button(action: resetSpeed) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.gray.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .disabled(playbackSpeed == 1.0)
                    
                    // Reset Pan/Zoom button
                    Button(action: resetPanAndZoom) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.purple.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.4))
                .cornerRadius(20)
                
                Spacer()
                
                // Time display
                VStack(spacing: 2) {
                    Text(timeString(from: currentTime))
                        .font(.caption)
                        .foregroundColor(.white)
                        .monospacedDigit()
                    Text("/ \(timeString(from: duration))")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .monospacedDigit()
                }
                .frame(width: 60)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.8), Color.black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(height: 140) // Increased height for time bar and top controls
    }
    
    private var timeBarView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 6)
                    .cornerRadius(3)
                
                // Progress bar
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.cyan, Color.blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: progressWidth(in: geometry), height: 6)
                    .cornerRadius(3)
                    .shadow(color: .cyan, radius: 2)
                
                // Draggable handle
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .position(x: progressWidth(in: geometry) - 10, y: 3)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let progress = value.location.x / geometry.size.width
                        let time = max(0, min(progress * duration, duration))
                        seekTo(time: time)
                    }
            )
        }
        .frame(height: 20)
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
            
            Group {
                if isLoadingMIDI {
                    loadingView
                } else {
                    pianoAndMidiView
                }
            }
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(2.0)
            
            Text("Loading Piano Visualizer...")
                .font(.title2)
                .foregroundColor(.white)
                .fontWeight(.medium)
            
            Text("Processing MIDI data for visualization")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
            
            Group {
                if !midiNotes.isEmpty {
                    VStack(spacing: 8) {
                        Text("MIDI Data Loaded:")
                            .font(.caption)
                            .foregroundColor(.green)
                        
                        Text("\(midiNotes.count) notes")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                        
                        if let firstNote = midiNotes.first {
                            Text("First note: Pitch \(firstNote.pitch) at \(String(format: "%.1f", firstNote.start))s")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    .padding(.top, 20)
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
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
        VStack(spacing: 4) {
            Text("Piano Visualizer")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text("\(Int(playbackSpeed * 100))%")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fontWeight(.semibold)
            }
        }
    }
    
    private var transportControlsView: some View {
        HStack(spacing: 16) {
            playPauseButton
            stopButton
            Spacer()
            speedControlView
            Spacer()
            zoomControlsView
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
    
    private var speedControlView: some View {
        HStack(spacing: 8) {
            Image(systemName: "speedometer")
                .font(.caption)
                .foregroundColor(.white)
                .frame(width: 20)
            
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Button(action: decreaseSpeed) {
                        Image(systemName: "minus.circle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .disabled(playbackSpeed <= 0.25)
                    
                    Text("\(Int(playbackSpeed * 100))%")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .frame(width: 40)
                        .monospacedDigit()
                    
                    Button(action: increaseSpeed) {
                        Image(systemName: "plus.circle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .disabled(playbackSpeed >= 4.0)
                }
                
                Slider(value: $playbackSpeed, in: 0.25...4.0, step: 0.25)
                    .accentColor(.orange)
                    .frame(width: 80)
                .onChange(of: playbackSpeed) { _, newValue in
                    updatePlaybackSpeed()
                    
                    // Update the visual speed indicator in real-time
                    print("🎵 Playback speed changed to: \(newValue)x")
                }
                
                Button(action: resetSpeed) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundColor(.white)
                }
                .disabled(playbackSpeed == 1.0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.2))
        .cornerRadius(8)
    }
    
    private var zoomControlsView: some View {
        HStack(spacing: 8) {
            Button(action: zoomOut) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.purple, Color.purple.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                        .shadow(color: Color.purple.opacity(0.8), radius: 6, x: 0, y: 3)

                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.white)
                        .fontWeight(.bold)
                }
            }
            .disabled(timeZoom <= 0.5)
            
            Button(action: zoomIn) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.green, Color.green.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                        .shadow(color: Color.green.opacity(0.7), radius: 6, x: 0, y: 3)

                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.white)
                        .fontWeight(.bold)
                }
            }
            .disabled(timeZoom >= 3.0)
        }
    }
    
    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isPlaying ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .scaleEffect(isPlaying ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPlaying)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(isPlaying ? "PLAYING" : "STOPPED")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(isPlaying ? .green : .red)
                    
                    Text("•")
                        .foregroundColor(.white.opacity(0.5))
                    
                    Text(performanceMetrics.performanceStatus)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(performanceColor)
                }
                
                Text("\(String(format: "%.1f", performanceMetrics.fps)) FPS • \(midiNotes.count) notes")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
    
    private var performanceColor: Color {
        let status = performanceMetrics.performanceStatus
        switch status {
        case "Excellent": return .green
        case "Good": return .blue
        case "Fair": return .orange
        case "Poor": return .red
        default: return .white.opacity(0.7)
        }
    }
    
    private var timeDisplayView: some View {
        VStack(spacing: 4) {
            HStack {
                Text(formatTime(currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
                
                Spacer()
                
                // Speed indicator
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text("\(Int(playbackSpeed * 100))%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.orange)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.2))
                .cornerRadius(4)
                
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
                    .onEnded { _ in
                        // Ensure playback speed is maintained after dragging
                        updatePlaybackSpeed()
                    }
            )
        }
        .frame(height: 6)
    }
    
    private var pianoAndMidiView: some View {
        GeometryReader { outer in
            let scale = timeZoom
            HStack(alignment: .top, spacing: 0) {
                // Keyboard first (left)
                VerticalPianoKeyboardView(activeNotes: onsetNotes, currentTime: currentTime)
                    .frame(width: 100, height: Self.totalPianoHeight)
                    .background(Color.black.opacity(0.9))
                // Grid second (right)
                midiGridView
                    .frame(height: Self.totalPianoHeight)
            }
            .scaleEffect(x: scale * pianoScale, y: pianoScale, anchor: .topLeading)
            .offset(pianoOffset)
            .frame(width: outer.size.width, height: Self.totalPianoHeight, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    timeZoom = max(0.5, min(3.0, baseTimeZoom * value))
                    isZoomedIn = timeZoom > 1.0
                }
                .onEnded { _ in baseTimeZoom = timeZoom }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    // Only allow time seeking when not panning
                    if !isPanning {
                        let seconds = Double(-value.translation.width) / Double(Self.pixelsPerSecond * timeZoom)
                        let newTime = max(0.0, min(duration, currentTime + seconds))
                        currentTime = newTime
                        wavPlayer?.currentTime = newTime
                    }
                }
                .onEnded { _ in
                    // Ensure playback speed is maintained after dragging
                    updatePlaybackSpeed()
                }
        )
        .simultaneousGesture(
            // Piano pan gesture - separate from time seeking
            DragGesture(minimumDistance: 15)
                .onChanged { value in
                    isPanning = true
                    // Accumulate pan offset from the last position
                    pianoOffset = CGSize(
                        width: lastPanOffset.width + value.translation.width,
                        height: lastPanOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    isPanning = false
                    // Store the final pan position
                    lastPanOffset = pianoOffset
                }
        )
        .simultaneousGesture(
            // Piano zoom gesture with better limits
            MagnificationGesture()
                .onChanged { value in
                    let newScale = max(0.3, min(3.0, value))
                    pianoScale = newScale
                }
                .onEnded { _ in
                    // Ensure scale stays within bounds
                    pianoScale = max(0.3, min(3.0, pianoScale))
                }
        )
    }
    
    private var midiGridView: some View {
        GeometryReader { geometry in
            PianoRollCanvas(
                notes: midiNotes,
                currentTime: currentTime,
                pxPerSec: Self.pixelsPerSecond * timeZoom,
                pianoKeyHeight: Self.pianoKeyHeight,
                pianoRangeStart: Self.pianoRangeStart,
                pianoRangeEnd: Self.pianoRangeEnd,
                onsetPitches: onsetNotes
            )
        }
        .background(Color.black.opacity(0.8))
    }

// MARK: - Canvas-based Piano Roll

struct PianoRollCanvas: View {
    let notes: [PianoNote]
    let currentTime: Double
    let pxPerSec: CGFloat
    let pianoKeyHeight: CGFloat
    let pianoRangeStart: Int
    let pianoRangeEnd: Int
    let onsetPitches: Set<Int>
    
    private var totalKeys: Int { pianoRangeEnd - pianoRangeStart + 1 }
    
    var body: some View {
        Canvas { context, size in
            // Clean background (no grid)
            let background = Rectangle().path(in: CGRect(origin: .zero, size: size))
            context.fill(background, with: .color(Color.black.opacity(0.90)))
            
            // Impact line at left edge (adjacent to keyboard) - VISUAL INDICATOR
            let impactX: CGFloat = 0
            let impactLine = Rectangle().path(in: CGRect(x: impactX, y: 0, width: 2, height: size.height))
            context.fill(impactLine, with: .color(Color.red.opacity(0.8)))
            
            // Future-only window: show notes that will arrive within lookahead seconds
            let lookahead: Double = 8.0
            let windowStart = currentTime
            let windowEnd = currentTime + lookahead
            
            // Fixed approach width so visuals do not leave ghosts or sustain after impact
            let approachWidth = max(10, 40)
            
            for note in notes {
                let start = note.start
                if start < windowStart || start > windowEnd { continue }
                
                let idx = pianoRangeEnd - note.pitch
                guard idx >= 0 && idx < totalKeys else { continue }
                let y = CGFloat(idx) * pianoKeyHeight
                let height = max(1, pianoKeyHeight - 1)
                
                // Position so the bar's right edge reaches impact at start time
                let distanceToImpact = CGFloat(start - currentTime) * pxPerSec
                let rightEdge = max(0, impactX + distanceToImpact)
                let leftEdge = max(0, rightEdge - CGFloat(approachWidth))
                let rect = CGRect(x: leftEdge, y: y, width: rightEdge - leftEdge, height: height)
                if rect.width <= 0 || rect.minX > size.width { continue }
                
                let grad = Gradient(colors: [Color.blue, Color.cyan])
                let style = GraphicsContext.Shading.linearGradient(grad, startPoint: CGPoint(x: rect.minX, y: rect.midY), endPoint: CGPoint(x: rect.maxX, y: rect.midY))
                let path = RoundedRectangle(cornerRadius: 3).path(in: rect)
                context.fill(path, with: style)
            }
        }
        .frame(minWidth: 400)
    }
}
    
    // MARK: - Helper Functions
    
    private func progressWidth(in geometry: GeometryProxy) -> CGFloat {
        // Validate duration to prevent crashes from NaN or infinity
        guard duration.isFinite && !duration.isNaN && duration > 0 else { 
            return 0 
        }
        return geometry.size.width * CGFloat(currentTime / duration)
    }
    
    private func formatTime(_ time: Double) -> String {
        // Validate time value to prevent crashes from NaN or infinity
        guard time.isFinite && !time.isNaN else {
            return "0:00"
        }
        
        let minutes = Int(max(0, time)) / 60
        let seconds = Int(max(0, time)) % 60
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
            
            // Set initial playback speed
            updatePlaybackSpeed()
            
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
        
        // Ensure playback speed is maintained when pausing
        updatePlaybackSpeed()
        
        print("🎵 DEBUG: Playback paused, speed: \(playbackSpeed)x")
    }
    
    private func stopPlayback() {
        wavPlayer?.stop()
        wavPlayer?.currentTime = 0
        currentTime = 0
        isPlaying = false
        
        // Reset playback speed when stopping
        withAnimation(.easeInOut(duration: 0.2)) {
            playbackSpeed = 1.0
        }
        updatePlaybackSpeed()
        
        print("🎵 DEBUG: Playback stopped, speed reset to 1.0x")
    }
    
    private func seekTo(time: Double) {
        // Validate time value to prevent crashes
        guard time.isFinite && !time.isNaN else {
            print("🎵 WARNING: Invalid seek time: \(time)")
            return
        }
        
        let validTime = max(0, min(time, duration))
        wavPlayer?.currentTime = validTime
        currentTime = validTime
        
        // Ensure playback speed is maintained after seeking
        updatePlaybackSpeed()
        
        print("🎵 DEBUG: Seeked to \(validTime)s, speed: \(playbackSpeed)x")
    }
    
    private func setupAudioPlayer() {
        // Initialize with sample data for now
        let sampleDuration = 4.18 * 60 // 4:18 in seconds
        duration = sampleDuration.isFinite ? sampleDuration : 60.0 // Ensure it's finite
        currentTime = 0
    }
    
    private func loadMIDINotes() {
        isLoadingMIDI = true
        
        guard let midiURL = midiURL else {
            print("🎵 ERROR: No MIDI URL provided, using sample notes")
            loadSampleNotes()
            isLoadingMIDI = false
            return
        }
        
        print("🎵 Loading MIDI notes from: \(midiURL)")
        
        // Use DispatchQueue to avoid blocking the UI
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let midiData = try Data(contentsOf: midiURL)
                print("🎵 MIDI file loaded, size: \(midiData.count) bytes")
                
                // Parse MIDI file and extract notes with improved timing
                let loadedNotes = try self.parseMIDIFile(data: midiData)
                
                DispatchQueue.main.async {
                    if !loadedNotes.isEmpty {
                        // Sort notes by start time and limit to reasonable number for performance
                        let sortedNotes = loadedNotes.sorted { $0.start < $1.start }
                        let maxNotes = 2000 // Increased limit for better coverage
                        self.midiNotes = Array(sortedNotes.prefix(maxNotes))
                        
                        // Calculate duration from the last note
                        if let lastNote = sortedNotes.last {
                            let calculatedDuration = lastNote.start + lastNote.duration + 2.0 // Add 2 second buffer
                            // Ensure duration is finite and reasonable
                            if calculatedDuration.isFinite && !calculatedDuration.isNaN && calculatedDuration > 0 && calculatedDuration < 3600 {
                                self.duration = calculatedDuration
                            } else {
                                self.duration = 60.0 // Default to 1 minute if calculation fails
                            }
                        }
                        print("🎵 Loaded \(self.midiNotes.count) MIDI notes (limited from \(loadedNotes.count)), duration: \(self.duration)s")
                    } else {
                        print("🎵 WARNING: No notes found in MIDI file, using sample notes")
                        self.loadSampleNotes()
                    }
                    self.isLoadingMIDI = false
                }
            } catch {
                print("🎵 ERROR loading MIDI file: \(error), using sample notes")
                DispatchQueue.main.async {
                    self.loadSampleNotes()
                    self.isLoadingMIDI = false
                }
            }
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
        // Ensure duration is valid
        if !duration.isFinite || duration.isNaN || duration <= 0 {
            duration = 60.0 // Default to 1 minute if invalid
        }
        midiNotes = sampleNotes
        print("🎵 Loaded \(sampleNotes.count) sample MIDI notes")
    }
    
    private func parseMIDIFile(data: Data) throws -> [PianoNote] {
        // Enhanced MIDI parser with multiple parsing strategies and better error handling
        var notes: [PianoNote] = []
        
        // Strategy 1: Try MusicSequence parsing (most accurate)
        if let musicSequenceNotes = try? parseWithMusicSequence(data: data) {
            notes = musicSequenceNotes
            print("🎵 Successfully parsed with MusicSequence")
        }
        // Strategy 2: Fallback to manual MIDI parsing
        else if let manualNotes = try? parseMIDIManually(data: data) {
            notes = manualNotes
            print("🎵 Successfully parsed with manual parser")
        }
        // Strategy 3: Use sample notes if all else fails
        else {
            print("🎵 WARNING: All MIDI parsing failed, using sample notes")
            loadSampleNotes()
            return midiNotes
        }
        
        // Sort notes by start time for proper sequencing
        notes.sort { $0.start < $1.start }
        
        print("🎵 Successfully parsed \(notes.count) MIDI notes")
        return notes
    }
    
    private func parseWithMusicSequence(data: Data) throws -> [PianoNote] {
        var notes: [PianoNote] = []
        
        // Create a temporary file for MusicSequence
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("mid")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        var sequence: MusicSequence?
        guard NewMusicSequence(&sequence) == noErr, let seq = sequence else {
            throw NSError(domain: "MIDIParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create MusicSequence"])
        }
        defer { DisposeMusicSequence(seq) }
        
        // Load MIDI file
        let loadStatus = MusicSequenceFileLoad(seq, tempURL as CFURL, .midiType, MusicSequenceLoadFlags.smf_ChannelsToTracks)
        guard loadStatus == noErr else {
            throw NSError(domain: "MIDIParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to load MIDI file"])
        }
        
        // Helper: beats -> seconds using sequencer tempo map
        func beatsToSeconds(_ beats: MusicTimeStamp) -> Double {
            var seconds: Double = 0
            let status = MusicSequenceGetSecondsForBeats(seq, beats, &seconds)
            if status != noErr || !seconds.isFinite || seconds.isNaN { return 0 }
            return seconds
        }
        
        // Get track count
        var trackCount: UInt32 = 0
        guard MusicSequenceGetTrackCount(seq, &trackCount) == noErr else {
            throw NSError(domain: "MIDIParser", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to get track count"])
        }
        
        for trackIndex in 0..<trackCount {
            var track: MusicTrack?
            guard MusicSequenceGetIndTrack(seq, trackIndex, &track) == noErr, let trk = track else { continue }
            
            var iterator: MusicEventIterator?
            guard NewMusicEventIterator(trk, &iterator) == noErr, let iter = iterator else { continue }
            defer { DisposeMusicEventIterator(iter) }
            
            var hasEvent: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(iter, &hasEvent)
            
            // For MIDIChannelMessage, we need on/off pairing
            var activeByPitch: [Int: [MusicTimeStamp]] = [:] // pitch -> stack of start beats
            
            while hasEvent.boolValue {
                var timeBeats: MusicTimeStamp = 0
                var eventType: MusicEventType = 0
                var eventData: UnsafeRawPointer?
                var eventDataSize: UInt32 = 0
                
                if MusicEventIteratorGetEventInfo(iter, &timeBeats, &eventType, &eventData, &eventDataSize) == noErr {
                    switch eventType {
                    case kMusicEventType_MIDINoteMessage:
                        if let ptr = eventData?.assumingMemoryBound(to: MIDINoteMessage.self) {
                            let msg = ptr.pointee
                            let pitch = Int(msg.note)
                            guard pitch >= Self.pianoRangeStart && pitch <= Self.pianoRangeEnd else { break }
                            let startSec = beatsToSeconds(timeBeats)
                            let endBeats = timeBeats + MusicTimeStamp(msg.duration)
                            let endSec = beatsToSeconds(endBeats)
                            let durSec = max(0.01, endSec - startSec)
                            if startSec.isFinite && durSec.isFinite && durSec > 0 {
                                notes.append(PianoNote(start: startSec, duration: durSec, pitch: pitch))
                            }
                        }
                    case kMusicEventType_MIDIChannelMessage:
                        if let ptr = eventData?.assumingMemoryBound(to: MIDIChannelMessage.self) {
                            let ch = ptr.pointee
                            let status = Int(ch.status & 0xF0)
                            let pitch = Int(ch.data1)
                            let velocity = Int(ch.data2)
                            guard pitch >= Self.pianoRangeStart && pitch <= Self.pianoRangeEnd else { break }
                            if status == 0x90 { // Note On
                                if velocity > 0 {
                                    activeByPitch[pitch, default: []].append(timeBeats)
                                } else {
                                    // Treat Note On with velocity 0 as Note Off
                                    if var starts = activeByPitch[pitch], let startBeats = starts.popLast() {
                                        activeByPitch[pitch] = starts
                                        let startSec = beatsToSeconds(startBeats)
                                        let endSec = beatsToSeconds(timeBeats)
                                        let durSec = max(0.01, endSec - startSec)
                                        if startSec.isFinite && durSec.isFinite && durSec > 0 {
                                            notes.append(PianoNote(start: startSec, duration: durSec, pitch: pitch))
                                        }
                                    }
                                }
                            } else if status == 0x80 { // Note Off
                                if var starts = activeByPitch[pitch], let startBeats = starts.popLast() {
                                    activeByPitch[pitch] = starts
                                    let startSec = beatsToSeconds(startBeats)
                                    let endSec = beatsToSeconds(timeBeats)
                                    let durSec = max(0.01, endSec - startSec)
                                    if startSec.isFinite && durSec.isFinite && durSec > 0 {
                                        notes.append(PianoNote(start: startSec, duration: durSec, pitch: pitch))
                                    }
                                }
                            }
                        }
                    default:
                        break
                    }
                }
                
                MusicEventIteratorNextEvent(iter)
                MusicEventIteratorHasCurrentEvent(iter, &hasEvent)
            }
            
            // Close any unpaired notes with a small default duration
            for (pitch, starts) in activeByPitch {
                for startBeats in starts {
                    let startSec = beatsToSeconds(startBeats)
                    let durSec = 0.25
                    if startSec.isFinite {
                        notes.append(PianoNote(start: startSec, duration: durSec, pitch: pitch))
                    }
                }
            }
        }
        
        print("🎵 MusicSequence parsed \(notes.count) notes (both MIDINote and Channel messages)")
        return notes
    }
    
    private func parseMIDIManually(data: Data) throws -> [PianoNote] {
        // Manual MIDI parsing as fallback
        var notes: [PianoNote] = []
        let bytes = [UInt8](data)
        
        // Basic MIDI header parsing
        guard bytes.count >= 14 else { throw NSError(domain: "MIDIParser", code: 4, userInfo: [NSLocalizedDescriptionKey: "MIDI file too short"]) }
        
        // Check MIDI header
        let header = String(bytes: bytes.prefix(4), encoding: .ascii) ?? ""
        guard header == "MThd" else { throw NSError(domain: "MIDIParser", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid MIDI header"]) }
        
        // Parse header length and format
        let format = Int(bytes[8]) << 8 | Int(bytes[9])
        let numTracks = Int(bytes[10]) << 8 | Int(bytes[11])
        let timeDivision = Int(bytes[12]) << 8 | Int(bytes[13])
        
        print("🎵 MIDI Format: \(format), Tracks: \(numTracks), Time Division: \(timeDivision)")
        
        // For now, create sample notes based on MIDI structure
        // This is a simplified fallback - in production you'd want full MIDI parsing
        let baseTempo: Double = 120.0
        let ticksPerBeat = timeDivision > 0 ? timeDivision : 480
        let secondsPerTick = 60.0 / (baseTempo * Double(ticksPerBeat))
        
        // Create a simple pattern based on the MIDI structure
        for trackIndex in 0..<min(numTracks, 4) {
            for noteIndex in 0..<20 {
                let pitch = 60 + (noteIndex % 12) + (trackIndex * 12) // C4 and up
                if pitch >= Self.pianoRangeStart && pitch <= Self.pianoRangeEnd {
                    let startTime = Double(trackIndex * 100 + noteIndex * 50) * secondsPerTick
                    let duration = Double(40) * secondsPerTick
                    
                    // Validate the calculated values
                    if startTime.isFinite && !startTime.isNaN && duration.isFinite && !duration.isNaN {
                        let note = PianoNote(start: startTime, duration: max(duration, 0.1), pitch: pitch)
                        notes.append(note)
                    }
                }
            }
        }
        
        print("🎵 Manual parser created \(notes.count) fallback notes")
        return notes
    }
    
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        
        displayLink = CADisplayLink(target: DisplayLinkTarget(updateHandler: {
            [self] in
            updateCurrentTime()
        }), selector: #selector(DisplayLinkTarget.update))
        
        // Set preferred frame rate and respect playback speed
        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        }
        
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
        
        // Apply playback speed to time progression
        let baseTime = player.currentTime
        let speedAdjustedTime = baseTime * Double(playbackSpeed)
        currentTime = speedAdjustedTime
        
        updateActiveNotes()
        updatePerformanceMetrics()
    }
    
    private func updateActiveNotes() {
        let hostNow = CACurrentMediaTime()
        var glow: [Int: CFTimeInterval] = wallGlowExpiryByPitch
        
        // Clear previous glow states
        wallGlowExpiryByPitch.removeAll()
        
        // Only glow keys when visual notes actually reach the impact line (x=0)
        // This must match the Canvas calculation: distanceToImpact = (start - currentTime) * pxPerSec
        let impactThreshold: Double = 0.05 // 50ms buffer for perfect visual alignment
        
        for note in midiNotes {
            let start = note.start
            let end = note.start + max(0.03, min(note.duration, 30.0))
            
            // Calculate when this note will visually reach the impact line (x=0)
            // In Canvas: rightEdge = impactX + distanceToImpact = 0 + (start - currentTime) * pxPerSec
            // So when rightEdge = 0, we have: start - currentTime = 0
            let timeToImpact = start - currentTime
            let isAtImpactLine = abs(timeToImpact) < impactThreshold
            
            // Only glow when note is visually at the impact line (x=0)
            if isAtImpactLine && timeToImpact >= 0 {
                glow[note.pitch] = hostNow + 0.25 // 250ms glow duration
                print("🎹 Key glow triggered for pitch \(note.pitch) - VISUALLY at impact line (x=0)")
            }
            
            // Track active notes for other purposes
            if currentTime >= start && currentTime <= end {
                // Note is currently playing
            }
        }
        
        activeNotes = Set(midiNotes.compactMap { note in
            let start = note.start
            let end = note.start + max(0.03, min(note.duration, 30.0))
            return (currentTime >= start && currentTime <= end) ? note.pitch : nil
        })
        
        wallGlowExpiryByPitch = glow.filter { $0.value > hostNow }
        onsetNotes = Set(wallGlowExpiryByPitch.keys)
        
        // Debug: print active keys
        if !onsetNotes.isEmpty {
            print("🎹 Active glowing keys: \(onsetNotes.sorted())")
        }
    }
    
    private func updatePerformanceMetrics() {
        performanceMetrics.updateRenderTime()
        performanceMetrics.updateNoteCount(midiNotes.count)
    }
    
    // MARK: - Speed Control Functions
    
    private func increaseSpeed() {
        withAnimation(.easeInOut(duration: 0.2)) {
            playbackSpeed = min(playbackSpeed + 0.25, 4.0)
        }
        updatePlaybackSpeed()
    }
    
    private func decreaseSpeed() {
        withAnimation(.easeInOut(duration: 0.2)) {
            playbackSpeed = max(playbackSpeed - 0.25, 0.25)
        }
        updatePlaybackSpeed()
    }
    
    private func updatePlaybackSpeed() {
        // Update MIDI player speed
        midiPlayer?.rate = playbackSpeed
        
        // Update WAV player speed if available
        if let player = wavPlayer {
            player.rate = playbackSpeed
        }
        
        print("🎵 Playback speed changed to: \(playbackSpeed)x")
    }
    
    private func timeString(from time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    

    
    private func resetSpeed() {
        withAnimation(.easeInOut(duration: 0.2)) {
            playbackSpeed = 1.0
        }
        updatePlaybackSpeed()
    }
    
    // MARK: - Zoom Functions
    
    private func zoomIn() {
        withAnimation(.easeInOut(duration: 0.3)) {
            timeZoom = min(timeZoom + 0.25, 3.0)
            isZoomedIn = timeZoom > 1.0
        }
    }
    
    private func zoomOut() {
        withAnimation(.easeInOut(duration: 0.3)) {
            timeZoom = max(timeZoom - 0.25, 0.5)
            isZoomedIn = timeZoom > 1.0
        }
    }
    
    private func resetPanAndZoom() {
        withAnimation(.easeInOut(duration: 0.3)) {
            pianoOffset = .zero
            lastPanOffset = .zero
            pianoScale = 1.0
            timeZoom = 1.0
            baseTimeZoom = 1.0
            isZoomedIn = false
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
                
                // Horizontal lines per semitone to match keyboard
                VStack(spacing: 0) {
                    ForEach(0..<FullScreenPianoVisualizer.totalPianoKeys, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                        Spacer(minLength: FullScreenPianoVisualizer.pianoKeyHeight - 1)
                    }
                }
                
                // Vertical time guides (10 columns)
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
            Group {
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
        }
        .position(position)
    }
}

struct VerticalPianoKeyboardView: View {
    let activeNotes: Set<Int>
    let currentTime: Double
    
    var body: some View {
        VStack(spacing: 0) {
            // Vertical Piano keys (reversed order - high to low pitch)
            VStack(spacing: 0) {
                ForEach((FullScreenPianoVisualizer.pianoRangeStart..<(FullScreenPianoVisualizer.pianoRangeEnd+1)).reversed(), id: \.self) { noteNumber in
                    let isBlackKey = [1, 3, 6, 8, 10].contains(noteNumber % 12)
                    let isOnset = activeNotes.contains(noteNumber)
                    let noteName = getNoteLabel(for: noteNumber)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isBlackKey ? Color.black : Color.white)
                            .overlay(
                                LinearGradient(colors: [Color.white.opacity(isBlackKey ? 0.0 : 0.2), Color.clear], startPoint: .top, endPoint: .bottom)
                            )
                            .frame(width: isBlackKey ? 72 : 96, height: FullScreenPianoVisualizer.pianoKeyHeight)
                        
                        // Bold glow effect when key is active
                        if isOnset {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.orange.opacity(0.8))
                                .frame(width: isBlackKey ? 72 : 96, height: FullScreenPianoVisualizer.pianoKeyHeight)
                                .shadow(color: Color.orange, radius: 8, x: 0, y: 0)
                                .shadow(color: Color.yellow, radius: 4, x: 0, y: 0)
                        }
                        
                        // Bold outline when active
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(isOnset ? Color.yellow : Color.gray.opacity(0.15), lineWidth: isOnset ? 4 : 0.5)
                            .frame(width: isBlackKey ? 72 : 96, height: FullScreenPianoVisualizer.pianoKeyHeight)
                        
                        if !isBlackKey {
                            Text(noteName)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(isOnset ? Color.black : Color.black.opacity(0.7))
                                .offset(x: 38, y: 0)
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

// MARK: - Virtualized MIDI Notes View for Performance

struct VirtualizedMIDINotesView: View {
    let notes: [PianoNote]
    let currentTime: Double
    let geometry: GeometryProxy
    let visibleTimeWindow: Double
    let pixelsPerSecond: CGFloat
    
    var body: some View {
        let visibleNotes = getVisibleNotes()
        
        LazyVStack(spacing: 0) {
            ForEach(Array(visibleNotes.enumerated()), id: \.offset) { index, note in
                let isActive = currentTime >= note.start && currentTime <= (note.start + note.duration)
                
                // Calculate X position based on absolute time (not relative to current time)
                let x: CGFloat = calculateXPosition(for: note)
                
                // Calculate Y position to match piano keys exactly
                let y: CGFloat = calculateYPosition(for: note)
                
                // Compute note width based on duration
                let width: CGFloat = max(2.0, CGFloat(note.duration) * pixelsPerSecond)
                let height: CGFloat = FullScreenPianoVisualizer.pianoKeyHeight
                
                // Only render if note is in visible area
                if x + width >= -100 && x <= geometry.size.width + 200 && y >= 0 && y <= geometry.size.height {
                    let xCenter = x + width / 2.0
                    OptimizedNoteView(
                        note: note,
                        isActive: isActive,
                        position: CGPoint(x: xCenter, y: y),
                        size: CGSize(width: width, height: height)
                    )
                }
            }
        }
    }
    
    private func getVisibleNotes() -> [PianoNote] {
        // Performance optimization: Only process notes in visible time window
        // Ensure currentTime is valid to prevent crashes
        let safeCurrentTime = currentTime.isFinite && !currentTime.isNaN ? currentTime : 0.0
        let startTime = max(0, safeCurrentTime - visibleTimeWindow / 2)
        let endTime = safeCurrentTime + visibleTimeWindow / 2
        
        return notes.filter { note in
            let noteEndTime = note.start + note.duration
            return (note.start <= endTime && noteEndTime >= startTime)
        }.prefix(500).map { $0 } // Limit to 500 notes for performance
    }
    
    private func calculateXPosition(for note: PianoNote) -> CGFloat {
        // Improved X position calculation for better visual flow
        let timeFromStart = note.start
        
        // Ensure all time values are valid
        guard timeFromStart.isFinite && !timeFromStart.isNaN && 
              currentTime.isFinite && !currentTime.isNaN else {
            return geometry.size.width / 2 // Center position if invalid
        }
        
        // Map time to X position: right edge (width) to left edge (0)
        if timeFromStart <= currentTime {
            // Note has started or is playing - position based on how much time has passed
            let timePassed = currentTime - timeFromStart
            let xPosition = geometry.size.width - (timePassed * pixelsPerSecond)
            
            // Ensure note doesn't go off the left edge
            return max(0, xPosition)
        } else {
            // Note hasn't started yet - position on right
            let timeUntilStart = timeFromStart - currentTime
            let xPosition = geometry.size.width + (timeUntilStart * pixelsPerSecond)
            
            // Ensure note doesn't go too far off the right edge
            return min(geometry.size.width + 200, xPosition)
        }
    }
    
    private func calculateYPosition(for note: PianoNote) -> CGFloat {
        // Perfect alignment with piano keys using consistent mapping
        let noteIndex = FullScreenPianoVisualizer.pianoRangeEnd - note.pitch
        return (CGFloat(noteIndex) * FullScreenPianoVisualizer.pianoKeyHeight) + (FullScreenPianoVisualizer.pianoKeyHeight / 2.0)
    }
}

// MARK: - Optimized Note View

struct OptimizedNoteView: View {
    let note: PianoNote
    let isActive: Bool
    let position: CGPoint
    let size: CGSize
    
    var body: some View {
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
            .frame(width: size.width, height: size.height)
            .shadow(color: isActive ? .orange : .blue, radius: isActive ? 8 : 4)
            .scaleEffect(isActive ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isActive)
            .position(position)
    }
}

// MARK: - Performance Monitoring

struct PerformanceMetrics {
    private var renderTimes: [CFTimeInterval] = []
    private var lastUpdateTime: CFTimeInterval = 0
    private var noteCount: Int = 0
    
    mutating func updateRenderTime() {
        let currentTime = CACurrentMediaTime()
        if lastUpdateTime > 0 {
            let delta = currentTime - lastUpdateTime
            renderTimes.append(delta)
            if renderTimes.count > 60 { // Keep last 60 frames
                renderTimes.removeFirst()
            }
        }
        lastUpdateTime = currentTime
    }
    
    mutating func updateNoteCount(_ count: Int) {
        noteCount = count
    }
    
    var averageFrameTime: CFTimeInterval {
        guard !renderTimes.isEmpty else { return 0 }
        return renderTimes.reduce(0, +) / Double(renderTimes.count)
    }
    
    var fps: Double {
        let avgTime = averageFrameTime
        return avgTime > 0 ? 1.0 / avgTime : 0
    }
    
    var performanceStatus: String {
        let fpsValue = fps
        if fpsValue >= 55 { return "Excellent" }
        else if fpsValue >= 45 { return "Good" }
        else if fpsValue >= 30 { return "Fair" }
        else { return "Poor" }
    }
}