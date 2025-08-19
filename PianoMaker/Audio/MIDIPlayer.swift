import Foundation
import AVFoundation
import AudioToolbox

final class MIDIPlayer {
    private var midiPlayer: AVMIDIPlayer?
    private(set) var isLoaded: Bool = false
    var gainDB: Float = 6.0

    func stop() {
        midiPlayer?.stop()
        midiPlayer = nil
        isLoaded = false
    }

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
#if DEBUG
        if let bankURL { print("MIDIPlayer using soundfont:", bankURL.path) } else { print("MIDIPlayer using default GM (no soundfont found)") }
#endif
        if let bank = bankURL {
            do {
                midiPlayer = try AVMIDIPlayer(contentsOf: inputURL, soundBankURL: bank)
            } catch {
                midiPlayer = try AVMIDIPlayer(contentsOf: inputURL, soundBankURL: nil)
            }
        } else {
            midiPlayer = try AVMIDIPlayer(contentsOf: inputURL, soundBankURL: nil)
        }
        midiPlayer?.prepareToPlay()
        isLoaded = true
    }

    func play() { midiPlayer?.play(nil) }

    func playMIDI(url: URL, bpm: Double? = nil) throws {
        try load(url: url)
        if let bpm, bpm > 0 { midiPlayer?.rate = Float(bpm / 120.0) }
        play()
    }

    func currentTime() -> TimeInterval { midiPlayer?.currentPosition ?? 0 }
    func duration() -> TimeInterval { midiPlayer?.duration ?? 0 }
    func seek(to seconds: TimeInterval) {
        guard let p = midiPlayer else { return }
        p.currentPosition = max(0, min(seconds, p.duration))
    }
}


