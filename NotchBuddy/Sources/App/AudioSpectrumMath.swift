import Foundation

/// Pure math of the sound visualizer: where the bands sit, how a level in dB becomes a bar
/// height, how bars rise and fall. Foundation only (tests/AudioSpectrumTests.swift).
enum AudioSpectrumMath {
    /// Lowest and highest frequencies the bars cover.
    static let lowFrequency: Float = 60
    static let highFrequency: Float = 12_000
    /// Band energy (dB, 0 = a full-scale sine) drawn as an empty bar, and as a full bar.
    /// Tuned on real music (TIDAL, measured with debugLogSpectrum): bands sit between about
    /// −60 and −17 dB, so −60…−6 squeezed every bar into 0.3–0.7 and they all looked alike.
    static let floorDB: Float = -50
    static let ceilingDB: Float = -15
    /// Smoothing per frame (~30 per second): bars jump up fast and fall slowly.
    static let attack: Float = 0.6
    static let release: Float = 0.15
    /// Bars closer than this to their last published height are not published again.
    static let publishThreshold: Float = 0.01

    /// `count + 1` log-spaced frequencies from `low` to `high`: band i spans edges[i]..<edges[i+1].
    static func bandEdges(count: Int, low: Float = lowFrequency, high: Float = highFrequency) -> [Float] {
        guard count > 0, low > 0, high > low else { return [] }
        let ratio = log(high / low)
        return (0...count).map { i in
            i == count ? high : low * exp(ratio * Float(i) / Float(count))
        }
    }

    /// The FFT bins (of `fftSize` points at `sampleRate`) that make up each band, as half-open
    /// ranges. Every band gets at least one bin and no bin is shared, so the low bands, narrower
    /// than a bin, still move; bins stay within 1..<fftSize/2 (no DC, no Nyquist).
    static func binRanges(edges: [Float], sampleRate: Float, fftSize: Int) -> [Range<Int>] {
        guard edges.count >= 2, sampleRate > 0, fftSize >= 4 else { return [] }
        let binWidth = sampleRate / Float(fftSize)
        let lastBin = fftSize / 2 - 1
        var ranges: [Range<Int>] = []
        var next = 1
        for i in 0..<(edges.count - 1) {
            let lower = max(next, Int((edges[i] / binWidth).rounded()))
            var upper = max(lower + 1, Int((edges[i + 1] / binWidth).rounded()))
            upper = min(upper, lastBin + 1)
            let start = min(lower, lastBin)
            ranges.append(start..<max(upper, start + 1))
            next = max(upper, start + 1)
        }
        return ranges
    }

    /// A level in dB as a bar height 0…1 (floor → 0, ceiling → 1, clamped).
    static func normalized(db: Float, floor: Float = floorDB, ceiling: Float = ceilingDB) -> Float {
        guard ceiling > floor, db.isFinite else { return 0 }
        return min(1, max(0, (db - floor) / (ceiling - floor)))
    }

    /// Energy (linear power, 1 = reference) in dB, never -infinity.
    static func decibels(power: Float) -> Float {
        10 * log10(max(power, 1e-12))
    }

    /// One frame of attack/release smoothing toward `target`. Tiny values snap to zero so a
    /// silent spectrum settles at exactly zero (and stops being published).
    static func smoothed(previous: Float, target: Float,
                         attack: Float = attack, release: Float = release) -> Float {
        let factor = target > previous ? attack : release
        let value = previous + (target - previous) * factor
        return value < 0.002 ? 0 : value
    }

    /// True when some bar moved enough since `published` to be worth a redraw.
    static func changedEnough(_ bands: [Float], since published: [Float],
                              threshold: Float = publishThreshold) -> Bool {
        guard bands.count == published.count else { return true }
        for i in bands.indices where abs(bands[i] - published[i]) > threshold { return true }
        // A bar that just reached zero is published, so the last frame shown is really empty.
        for i in bands.indices where bands[i] == 0 && published[i] != 0 { return true }
        return false
    }
}
