import Foundation

// Times the visualizer's analysis (SpectrumAnalyzer + SampleRing) on synthetic audio.
// Run through scripts/bench-audio-analysis.sh.

@main
enum BenchAudioAnalysis {
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func main() {
        let rate: Float = 48_000
        let ioFrames = 512                       // a typical HAL buffer
        let seconds = 2_000                      // of audio, per signal
        let ticks = seconds * 30                 // analysis frames at 30 Hz
        var rng = SystemRandomNumberGenerator()
        let signals: [(String, (Int) -> Float)] = [
            ("silence", { _ in 0 }),
            ("sine 1 kHz", { sinf(2 * .pi * 1000 * Float($0) / rate) }),
            ("3 sines", { i in
                let t = Float(i) / rate
                return 0.4 * sinf(2 * .pi * 80 * t) + 0.3 * sinf(2 * .pi * 900 * t) + 0.2 * sinf(2 * .pi * 7000 * t)
            }),
            ("white noise", { _ in Float.random(in: -0.5...0.5, using: &rng) }),
        ]
        print("fft 2048 points, 12 bands, \(ticks) analysis frames per signal (\(seconds) s at 30 Hz)")
        print("signal          analysis µs/frame   ring write µs/IO buffer (\(ioFrames) stereo frames)   CPU at 30 Hz")
        for (name, signal) in signals {
            // Stereo interleaved source, one IO buffer's worth, refreshed per tick so the
            // analysis sees changing audio.
            var stereo = [Float](repeating: 0, count: ioFrames * 2)
            let ring = SampleRing()
            let analyzer = SpectrumAnalyzer(fftSize: 2048, bandCount: 12, sampleRate: rate)
            var sample = 0
            var ringNanos: UInt64 = 0, ringCalls = 0
            var analysisNanos: UInt64 = 0
            var checksum: Float = 0
            for _ in 0..<ticks {
                // 1600 samples per tick at 48 kHz: about three IO buffers.
                for _ in 0..<3 {
                    for f in 0..<ioFrames {
                        let v = signal(sample); sample += 1
                        stereo[2 * f] = v; stereo[2 * f + 1] = v
                    }
                    let t0 = now()
                    stereo.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: ioFrames, channels: 2) }
                    ringNanos += now() - t0; ringCalls += 1
                }
                let t1 = now()
                ring.copyLatest(analyzer.fftSize, into: analyzer.input)
                analyzer.process()
                analysisNanos += now() - t1
                checksum += analyzer.levels[5]
            }
            let perFrame = Double(analysisNanos) / Double(ticks) / 1000
            let perIO = Double(ringNanos) / Double(ringCalls) / 1000
            // CPU share: 30 analyses per second plus the ring writes of one second of audio.
            let cpu = (perFrame * 30 + perIO * Double(rate) / Double(ioFrames)) / 1_000_000 * 100
            let label = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("\(label)\(String(format: "%8.2f", perFrame))            \(String(format: "%8.3f", perIO))                                  \(String(format: "%.3f", cpu)) %   (\(checksum.isFinite ? "ok" : "nan"))")
        }
    }
}
