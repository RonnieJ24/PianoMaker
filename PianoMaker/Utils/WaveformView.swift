import SwiftUI
import AVFoundation
import Accelerate

struct WaveformView: View {
    let url: URL
    @State private var samples: [CGFloat] = []

    var body: some View {
        GeometryReader { geo in
            let barWidth = max(1.0, geo.size.width / CGFloat(max(1, samples.count)))
            HStack(alignment: .center, spacing: 1) {
                ForEach(0..<samples.count, id: \.self) { i in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: barWidth, height: max(1, samples[i] * geo.size.height))
                }
            }
        }
        .onAppear { Task { await loadSamples() } }
        .frame(height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        let frameCount = Int(buffer.frameLength)
        let window = max(1, frameCount / 200)
        var values: [Float] = []
        var i = 0
        while i < frameCount {
            let end = min(frameCount, i + window)
            var sum: Float = 0
            vDSP_svesq(channel.advanced(by: i), 1, &sum, vDSP_Length(end - i))
            let mean = sum / Float(end - i)
            values.append(sqrtf(mean))
            i += window
        }
        return values
    }

    private func normalize(_ values: [Float]) -> [CGFloat] {
        guard let maxVal = values.max(), maxVal > 0 else { return values.map { _ in 0.1 } }
        return values.map { CGFloat($0 / maxVal) }
    }

    private func loadSamples() async {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let values = rms(buf)
            await MainActor.run { samples = normalize(values) }
        } catch {
            await MainActor.run { samples = [] }
        }
    }
}


