import Foundation
import AVFoundation
import AudioToolbox
import Combine

class EnhancedMIDIPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var currentNotes: [Int] = []
    @Published var currentChord: Chord?
    
    private var midiPlayer: AVMIDIPlayer?
    private var displayLink: CADisplayLink?
    private var chordDetector: ChordDetector
    private var timer: Timer?
    private var gainDB: Float = 6.0
    private var _isLoaded: Bool = false
    
    init() {
        self.chordDetector = ChordDetector()
    }
    
    func load(url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        
        stop()
        
        var inputURL = url
        if gainDB > 0.1 {
            if let boosted = try? boostedMIDIURL(from: url, gainDB: gainDB) { inputURL = boosted }
        }
        
        let bankURL = findSoundFont()
        if let bank = bankURL {
            midiPlayer = try AVMIDIPlayer(contentsOf: inputURL, soundBankURL: bank)
        } else {
            // Use a default sound bank if none is found
            midiPlayer = try AVMIDIPlayer(contentsOf: inputURL, soundBankURL: nil)
        }
        
        duration = midiPlayer?.duration ?? 0
        _isLoaded = true
    }
    
    func play() {
        guard let player = midiPlayer else { return }
        
        player.play { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.stopPlaybackTracking()
            }
        }
        
        isPlaying = true
        startPlaybackTracking()
    }
    
    func pause() {
        midiPlayer?.stop()
        isPlaying = false
        stopPlaybackTracking()
    }
    
    func stop() {
        midiPlayer?.stop()
        midiPlayer = nil
        isPlaying = false
        currentTime = 0
        currentNotes = []
        currentChord = nil
        stopPlaybackTracking()
        chordDetector.reset()
        _isLoaded = false
    }
    
    func seek(to time: Double) {
        guard let player = midiPlayer else { return }
        player.currentPosition = time
        currentTime = time
        updateCurrentNotes()
    }
    
    private func startPlaybackTracking() {
        // Start display link for smooth UI updates
        displayLink = CADisplayLink(target: self, selector: #selector(updatePlayback))
        displayLink?.add(to: .main, forMode: .common)
        
        // Start timer for chord detection
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateCurrentNotes()
        }
    }
    
    private func stopPlaybackTracking() {
        displayLink?.invalidate()
        displayLink = nil
        timer?.invalidate()
        timer = nil
    }
    
    @objc private func updatePlayback() {
        guard let player = midiPlayer else { return }
        currentTime = player.currentPosition
    }
    
    private func updateCurrentNotes() {
        guard let player = midiPlayer else { return }
        
        // Get current notes at current time
        let notes = getNotesAtTime(player.currentPosition)
        currentNotes = notes
        
        // Update chord detection using the improved method
        chordDetector.analyzeMIDIAtTime(player.currentPosition)
        currentChord = chordDetector.currentChord
    }
    
    private func getNotesAtTime(_ time: Double) -> [Int] {
        // This method now works with the chord detector's note data
        // The chord detector will handle the actual note analysis
        return []
    }
    
    // MARK: - SoundFont Management
    
    private func findSoundFont() -> URL? {
        // 0) Prefer user-provided SHC Splash Screen soundfont if present
        if let url = Bundle.main.url(forResource: "SHC_Splash_Screen_Soundfont", withExtension: "sf2", subdirectory: "Resources/SoundFonts")
            ?? Bundle.main.url(forResource: "SHC_Splash_Screen_Soundfont", withExtension: "sf2") {
            return url
        }
        // 1) Prefer Salamander-light name if present (more realistic piano)
        if let url = Bundle.main.url(forResource: "SalC5Light2", withExtension: "sf2", subdirectory: "Resources/SoundFonts")
            ?? Bundle.main.url(forResource: "SalC5Light2", withExtension: "sf2") {
            return url
        }
        // 2) Otherwise prefer FluidR3_GM (robust GM set)
        if let url = Bundle.main.url(forResource: "FluidR3_GM", withExtension: "sf2", subdirectory: "Resources/SoundFonts")
            ?? Bundle.main.url(forResource: "FluidR3_GM", withExtension: "sf2") {
            return url
        }
        // 3) Otherwise pick any .sf2 in the SoundFonts folder
        if let urls = Bundle.main.urls(forResourcesWithExtension: "sf2", subdirectory: "Resources/SoundFonts"), let first = urls.first {
            return first
        }
        // 4) Or any .sf2 in bundle
        if let urls = Bundle.main.urls(forResourcesWithExtension: "sf2", subdirectory: nil), let first = urls.first {
            return first
        }
        return nil
    }
    
    private func boostedMIDIURL(from url: URL, gainDB: Float) throws -> URL {
        let scale = pow(10.0, gainDB / 20.0)
        
        var sequenceOpt: MusicSequence?
        guard NewMusicSequence(&sequenceOpt) == noErr, let sequence = sequenceOpt else {
            return url
        }
        defer { DisposeMusicSequence(sequence) }
        
        let loadStatus = MusicSequenceFileLoad(sequence, url as CFURL, .midiType, MusicSequenceLoadFlags.smf_ChannelsToTracks)
        if loadStatus != noErr { return url }
        
        var trackCount: UInt32 = 0
        if MusicSequenceGetTrackCount(sequence, &trackCount) != noErr { return url }
        
        for i in 0..<trackCount {
            var trackOpt: MusicTrack?
            if MusicSequenceGetIndTrack(sequence, i, &trackOpt) != noErr { continue }
            guard let track = trackOpt else { continue }
            
            var itOpt: MusicEventIterator?
            guard NewMusicEventIterator(track, &itOpt) == noErr, let it = itOpt else { continue }
            defer { DisposeMusicEventIterator(it) }
            
            var hasEvent: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(it, &hasEvent)
            while hasEvent.boolValue {
                var time: MusicTimeStamp = 0
                var eventType: MusicEventType = 0
                var eventData: UnsafeRawPointer?
                var eventDataSize: UInt32 = 0
                if MusicEventIteratorGetEventInfo(it, &time, &eventType, &eventData, &eventDataSize) == noErr,
                   eventType == kMusicEventType_MIDINoteMessage,
                   let ptr = eventData?.assumingMemoryBound(to: MIDINoteMessage.self) {
                    var msg = ptr.pointee
                    let v = min(127, Int(round(Float(msg.velocity) * scale)))
                    msg.velocity = UInt8(max(1, v))
                    _ = MusicEventIteratorSetEventInfo(it, eventType, &msg)
                }
                MusicEventIteratorNextEvent(it)
                MusicEventIteratorHasCurrentEvent(it, &hasEvent)
            }
        }
        
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("mid")
        let writeStatus = MusicSequenceFileCreate(sequence, tmp as CFURL, .midiType, MusicSequenceFileFlags.eraseFile, 480)
        if writeStatus == noErr { return tmp }
        return url
    }
    
    // MARK: - Public Properties
    
    var isLoaded: Bool {
        return _isLoaded
    }
}
