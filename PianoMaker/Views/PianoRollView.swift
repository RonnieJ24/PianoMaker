import SwiftUI
import AVFoundation
import AudioToolbox

struct PianoNote: Identifiable {
    let id = UUID()
    let start: Double
    let duration: Double
    let pitch: Int
}

struct PianoRollView: View {
    let midiURL: URL
    @State private var notes: [PianoNote] = []
    @State private var zoomX: CGFloat = 30
    @State private var zoomY: CGFloat = 6

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Canvas { context, size in
                // Draw grid
                let width = size.width
                let height = size.height
                let cols = Int(width / zoomX)
                let rows = Int(height / zoomY)
                let gridColor = Color.secondary.opacity(0.15)
                for i in 0...cols {
                    let x = CGFloat(i) * zoomX
                    context.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: height)) }, with: .color(gridColor), lineWidth: 0.5)
                }
                for j in 0...rows {
                    let y = CGFloat(j) * zoomY
                    context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: width, y: y)) }, with: .color(gridColor), lineWidth: 0.5)
                }

                // Draw notes
                for note in notes {
                    let x = CGFloat(note.start) * zoomX
                    let w = CGFloat(note.duration) * zoomX
                    let y = CGFloat(108 - note.pitch) * zoomY
                    let rect = CGRect(x: x, y: y, width: max(2, w), height: max(2, zoomY - 1))
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.blue.opacity(0.7)))
                }
            }
            .frame(width: contentWidth, height: contentHeight)
            .gesture(MagnificationGesture().onChanged { value in
                let newZoomX = (zoomX * value).clamped(to: 10...80)
                let newZoomY = (zoomY * value).clamped(to: 3...14)
                zoomX = newZoomX
                zoomY = newZoomY
            })
        }
        .onAppear { loadMIDI() }
    }

    private var contentWidth: CGFloat {
        guard let maxEnd = notes.map({ $0.start + $0.duration }).max() else { return 600 }
        return CGFloat(maxEnd) * zoomX + 200
    }

    private var contentHeight: CGFloat {
        return CGFloat((108 - 21) + 4) * zoomY
    }

    private func loadMIDI() {
        var sequence: MusicSequence? = nil
        NewMusicSequence(&sequence)
        guard let seq = sequence else { return }
        let status = MusicSequenceFileLoad(seq, midiURL as CFURL, .midiType, MusicSequenceLoadFlags())
        guard status == noErr else { return }

        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(seq, &trackCount)

        var results: [PianoNote] = []
        for i in 0..<trackCount {
            var track: MusicTrack? = nil
            MusicSequenceGetIndTrack(seq, i, &track)
            guard let t = track else { continue }
            var iterator: MusicEventIterator? = nil
            NewMusicEventIterator(t, &iterator)
            guard let it = iterator else { continue }
            var hasEvent: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(it, &hasEvent)
            while hasEvent.boolValue {
                var timeStamp: MusicTimeStamp = 0
                var eventType: MusicEventType = 0
                var eventData: UnsafeRawPointer? = nil
                var eventDataSize: UInt32 = 0
                MusicEventIteratorGetEventInfo(it, &timeStamp, &eventType, &eventData, &eventDataSize)
                if eventType == kMusicEventType_MIDINoteMessage, let data = eventData?.assumingMemoryBound(to: MIDINoteMessage.self) {
                    let msg = data.pointee
                    results.append(PianoNote(start: timeStamp, duration: Double(msg.duration), pitch: Int(msg.note)))
                }
                MusicEventIteratorNextEvent(it)
                MusicEventIteratorHasCurrentEvent(it, &hasEvent)
            }
            DisposeMusicEventIterator(it)
        }
        self.notes = results
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}


