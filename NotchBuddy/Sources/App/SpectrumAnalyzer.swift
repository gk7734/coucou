import Accelerate
import Foundation
import Synchronization

/// Mono samples handed from the audio IO thread to the analyser, without locks: one writer
/// (the IOProc), one reader (the analysis queue). The writer publishes how many samples it has
/// written with a release store; the reader copies the latest window after an acquire load.
/// Nothing here allocates once built, so `write` is safe on the real-time thread.
final class SampleRing: @unchecked Sendable {
    static let capacity = 8192   // power of two, several FFT windows of slack
    private static let mask = capacity - 1

    private let storage: UnsafeMutablePointer<Float>
    /// Total samples written since creation (wraps only after centuries of audio).
    private let written = Atomic<Int>(0)

    init() {
        storage = .allocate(capacity: Self.capacity)
        storage.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { storage.deallocate() }

    /// Real-time thread: appends `frames` interleaved frames of `channels` channels, mixed to mono.
    func write(_ source: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        var index = written.load(ordering: .relaxed)
        if channels == 1 {
            for frame in 0..<frames {
                storage[index & Self.mask] = source[frame]
                index &+= 1
            }
        } else {
            let scale = 1 / Float(channels)
            var sample = source
            for _ in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += sample[channel] }
                storage[index & Self.mask] = sum * scale
                index &+= 1
                sample += channels
            }
        }
        written.store(index, ordering: .releasing)
    }

    /// Copies the latest `count` samples (oldest first) into `destination`. Returns the running
    /// total of samples written, so the caller can tell whether anything new arrived; when fewer
    /// than `count` samples exist yet, `destination` is left untouched.
    @discardableResult
    func copyLatest(_ count: Int, into destination: UnsafeMutablePointer<Float>) -> Int {
        let end = written.load(ordering: .acquiring)
        guard count > 0, count <= Self.capacity, end >= count else { return end }
        let start = (end - count) & Self.mask
        let firstPart = min(count, Self.capacity - start)
        destination.update(from: storage + start, count: firstPart)
        if firstPart < count {
            (destination + firstPart).update(from: storage, count: count - firstPart)
        }
        return end
    }
}

/// Turns a window of mono samples into `bandCount` smoothed bar heights 0…1: Hann window,
/// real FFT (vDSP), energy summed per log-spaced band, dB, normalised, attack/release.
/// All buffers are allocated once; `process` and `decay` allocate nothing. Not thread-safe:
/// one queue owns an analyser.
final class SpectrumAnalyzer {
    let fftSize: Int
    let bandCount: Int
    private(set) var sampleRate: Float
    /// The window to analyse: fill it (e.g. `SampleRing.copyLatest`) then call `process()`.
    let input: UnsafeMutablePointer<Float>
    /// Smoothed bar heights 0…1, low to high.
    private(set) var levels: [Float]
    /// Unsmoothed band energies of the last processed window, in dB (0 = a full-scale sine).
    private(set) var decibels: [Float]

    private var ranges: [Range<Int>]
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    /// Band energy of a full-scale sine through this window and FFT (vDSP's real FFT doubles
    /// the amplitude; a Hann window keeps a quarter of it at the peak bin, half at each side).
    private let referencePower: Float

    init(fftSize: Int = 2048, bandCount: Int, sampleRate: Float) {
        precondition(fftSize >= 64 && fftSize & (fftSize - 1) == 0, "fftSize must be a power of two")
        self.fftSize = fftSize
        self.bandCount = bandCount
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        self.setup = setup
        input = .allocate(capacity: fftSize)
        input.initialize(repeating: 0, count: fftSize)
        window = .allocate(capacity: fftSize)
        vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        windowed = .allocate(capacity: fftSize)
        windowed.initialize(repeating: 0, count: fftSize)
        real = .allocate(capacity: fftSize / 2)
        real.initialize(repeating: 0, count: fftSize / 2)
        imag = .allocate(capacity: fftSize / 2)
        imag.initialize(repeating: 0, count: fftSize / 2)
        power = .allocate(capacity: fftSize / 2)
        power.initialize(repeating: 0, count: fftSize / 2)
        let n = Float(fftSize)
        referencePower = 3 * n * n / 8
        levels = Array(repeating: 0, count: bandCount)
        decibels = Array(repeating: AudioSpectrumMath.floorDB, count: bandCount)
        ranges = AudioSpectrumMath.binRanges(
            edges: AudioSpectrumMath.bandEdges(count: bandCount),
            sampleRate: sampleRate, fftSize: fftSize)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        input.deallocate(); window.deallocate(); windowed.deallocate()
        real.deallocate(); imag.deallocate(); power.deallocate()
    }

    func setSampleRate(_ rate: Float) {
        guard rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        ranges = AudioSpectrumMath.binRanges(
            edges: AudioSpectrumMath.bandEdges(count: bandCount), sampleRate: rate, fftSize: fftSize)
    }

    /// Analyses `input` and moves `levels` one frame toward it.
    func process() {
        let half = fftSize / 2
        vDSP_vmul(input, 1, window, 1, windowed, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        real[0] = 0   // DC
        imag[0] = 0   // Nyquist, packed there by the real FFT
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(half))
        for band in 0..<min(bandCount, ranges.count) {
            let range = ranges[band]
            var sum: Float = 0
            vDSP_sve(power + range.lowerBound, 1, &sum, vDSP_Length(range.count))
            let db = AudioSpectrumMath.decibels(power: sum / referencePower)
            decibels[band] = db
            levels[band] = AudioSpectrumMath.smoothed(
                previous: levels[band], target: AudioSpectrumMath.normalized(db: db))
        }
    }

    /// No new audio this frame: the bars fall back toward zero.
    func decay() {
        for band in 0..<bandCount {
            levels[band] = AudioSpectrumMath.smoothed(previous: levels[band], target: 0)
        }
    }

    func reset() {
        for band in 0..<bandCount { levels[band] = 0 }
    }
}
