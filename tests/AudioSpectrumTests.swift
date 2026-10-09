import Foundation

@main
enum AudioSpectrumTests {
    static func close(_ a: Float, _ b: Float, _ tolerance: Float = 0.001) -> Bool { abs(a - b) <= tolerance }

    static func main() {
        // Band edges: 12 log-spaced bands from 60 Hz to 12 kHz, each the same ratio wide.
        let edges = AudioSpectrumMath.bandEdges(count: 12)
        precondition(edges.count == 13)
        precondition(edges.first == 60 && edges.last == 12_000)
        let ratio = edges[1] / edges[0]
        for i in 1..<12 { precondition(close(edges[i + 1] / edges[i], ratio, 0.001)) }
        precondition(close(ratio, pow(200, 1.0 / 12), 0.001))
        precondition(AudioSpectrumMath.bandEdges(count: 0).isEmpty)
        precondition(AudioSpectrumMath.bandEdges(count: 4, low: 100, high: 50).isEmpty)

        // Bins: every band has at least one, none is shared, no DC, nothing past Nyquist.
        for (rate, size) in [(Float(48_000), 2048), (44_100, 2048), (48_000, 1024), (96_000, 2048), (8_000, 256)] {
            let ranges = AudioSpectrumMath.binRanges(edges: edges, sampleRate: rate, fftSize: size)
            precondition(ranges.count == 12)
            precondition(ranges[0].lowerBound >= 1)
            for r in ranges { precondition(!r.isEmpty && r.upperBound <= size / 2) }
            for i in 1..<ranges.count {
                // Below Nyquist no bin is shared; above it the top bands share the last bin.
                if rate / 2 > edges.last! {
                    precondition(ranges[i].lowerBound >= ranges[i - 1].upperBound)
                } else {
                    precondition(ranges[i].lowerBound >= ranges[i - 1].lowerBound)
                }
            }
        }
        // At 48 kHz / 2048 points (23.4 Hz per bin) 1 kHz falls in the band that spans it.
        let ranges48 = AudioSpectrumMath.binRanges(edges: edges, sampleRate: 48_000, fftSize: 2048)
        let bin1k = Int((1000 / (48_000 / 2048.0)).rounded())
        let band1k = edges.indices.dropLast().first { edges[$0] <= 1000 && 1000 < edges[$0 + 1] }!
        precondition(ranges48[band1k].contains(bin1k))

        // dB → 0…1.
        precondition(AudioSpectrumMath.normalized(db: -60) == 0)
        precondition(AudioSpectrumMath.normalized(db: -90) == 0)
        precondition(AudioSpectrumMath.normalized(db: AudioSpectrumMath.ceilingDB) == 1)
        precondition(AudioSpectrumMath.normalized(db: 6) == 1)
        precondition(close(AudioSpectrumMath.normalized(db: -30, floor: -60, ceiling: 0), 0.5))
        precondition(AudioSpectrumMath.normalized(db: -.infinity) == 0)
        precondition(AudioSpectrumMath.normalized(db: .nan) == 0)
        precondition(AudioSpectrumMath.decibels(power: 1) == 0)
        precondition(close(AudioSpectrumMath.decibels(power: 0.001), -30))
        precondition(AudioSpectrumMath.decibels(power: 0).isFinite)

        // Smoothing: fast attack, slow release, settles at exactly zero.
        precondition(close(AudioSpectrumMath.smoothed(previous: 0, target: 1), 0.6))
        precondition(close(AudioSpectrumMath.smoothed(previous: 1, target: 0), 0.85))
        var level: Float = 1
        var frames = 0
        while level > 0 { level = AudioSpectrumMath.smoothed(previous: level, target: 0); frames += 1 }
        precondition(frames > 10 && frames < 60, "a full bar falls in about a second, got \(frames) frames")
        var rising: Float = 0
        for _ in 0..<4 { rising = AudioSpectrumMath.smoothed(previous: rising, target: 1) }
        precondition(rising > 0.95)

        // Publishing: only real changes, and the final drop to zero.
        let a: [Float] = [0.5, 0.2, 0]
        precondition(!AudioSpectrumMath.changedEnough([0.505, 0.2, 0], since: a))
        precondition(AudioSpectrumMath.changedEnough([0.52, 0.2, 0], since: a))
        precondition(AudioSpectrumMath.changedEnough([0.5, 0, 0], since: [0.5, 0.005, 0]))
        precondition(AudioSpectrumMath.changedEnough([0.5], since: a))
        precondition(!AudioSpectrumMath.changedEnough(a, since: a))

        // Ring buffer: mono mix, wrap-around, latest window first-to-last.
        let ring = SampleRing()
        let window = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        defer { window.deallocate() }
        precondition(ring.copyLatest(8, into: window) == 0)
        let stereo: [Float] = [1, 3, 2, 4, 3, 5]   // three frames → 2, 3, 4
        stereo.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 3, channels: 2) }
        precondition(ring.copyLatest(3, into: window) == 3)
        precondition(window[0] == 2 && window[1] == 3 && window[2] == 4)
        var counter: Float = 0
        var chunk = [Float](repeating: 0, count: 1000)
        for _ in 0..<10 {   // 10 000 samples: wraps the 8192-sample ring
            for i in chunk.indices { counter += 1; chunk[i] = counter }
            chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 1000, channels: 1) }
        }
        precondition(ring.copyLatest(8, into: window) == 10_003)
        for i in 0..<8 { precondition(window[i] == Float(10_000 - 7 + i)) }

        // Analyser: a full-scale sine reads ≈ 0 dB in its band and lights only around it.
        let analyzer = SpectrumAnalyzer(fftSize: 2048, bandCount: 12, sampleRate: 48_000)
        func fill(_ f: (Int) -> Float) { for i in 0..<analyzer.fftSize { analyzer.input[i] = f(i) } }
        fill { sinf(2 * .pi * 1000 * Float($0) / 48_000) }
        analyzer.process()
        precondition(abs(analyzer.decibels[band1k]) < 1.5, "full-scale sine: \(analyzer.decibels[band1k]) dB")
        for band in 0..<12 where abs(band - band1k) > 1 {
            precondition(analyzer.decibels[band] < -40, "leak into band \(band): \(analyzer.decibels[band]) dB")
        }
        precondition(analyzer.levels.indices.max { analyzer.levels[$0] < analyzer.levels[$1] } == band1k)
        // A quieter sine reads lower, by its gain.
        fill { 0.01 * sinf(2 * .pi * 1000 * Float($0) / 48_000) }
        analyzer.process()
        precondition(abs(analyzer.decibels[band1k] + 40) < 1.5)
        // A low sine (80 Hz) lands in the first bands; a high one (9 kHz) in the last ones.
        fill { sinf(2 * .pi * 80 * Float($0) / 48_000) }
        analyzer.process()
        let lowPeak = analyzer.decibels.indices.max { analyzer.decibels[$0] < analyzer.decibels[$1] }!
        precondition(lowPeak <= 1, "80 Hz peaks in band \(lowPeak)")
        fill { sinf(2 * .pi * 9000 * Float($0) / 48_000) }
        analyzer.process()
        let highPeak = analyzer.decibels.indices.max { analyzer.decibels[$0] < analyzer.decibels[$1] }!
        precondition(highPeak >= 10, "9 kHz peaks in band \(highPeak)")
        // Silence reads as the floor and the bars fall to zero.
        fill { _ in 0 }
        for _ in 0..<80 { analyzer.process() }
        precondition(analyzer.levels.allSatisfy { $0 == 0 })
        for band in 0..<12 { precondition(analyzer.decibels[band] <= AudioSpectrumMath.floorDB) }
        // Without new audio the bars decay too.
        fill { sinf(2 * .pi * 1000 * Float($0) / 48_000) }
        analyzer.process()
        precondition(analyzer.levels[band1k] > 0.5)
        for _ in 0..<80 { analyzer.decay() }
        precondition(analyzer.levels.allSatisfy { $0 == 0 })
        // Another sample rate moves the bins, not the bands.
        analyzer.setSampleRate(44_100)
        fill { sinf(2 * .pi * 1000 * Float($0) / 44_100) }
        analyzer.process()
        precondition(abs(analyzer.decibels[band1k]) < 1.5)

        print("AudioSpectrumTests: all passed")
    }
}
