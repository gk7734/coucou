// Compares snapshot PNGs against their baselines (scripts/snapshot.sh).
//
//   swiftc -O scripts/SnapshotCompare.swift -o /tmp/snapshot-compare
//   snapshot-compare <baseline dir> <current dir> <diff dir> [--threshold 0.5] [--tolerance 16]
//
// For each <case>.png in the baseline dir: a pixel differs when any of its channels moved
// by more than `tolerance` (0–255, absorbs anti-aliasing noise). A case fails when more than
// `threshold` % of its pixels differ, when its size changed, or when the current run did not
// produce it; a PNG with no baseline is reported as new (a failure too: run --update).
// Each failure writes <diff dir>/<case>.png: baseline | current | differing pixels in red.
// Exit 0 when every case passes, 1 otherwise, 2 on bad arguments.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Bitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]   // RGBA, premultiplied, sRGB, top row first

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(image: image)
    }

    init?(image: CGImage) {
        width = image.width
        height = image.height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !drawn { return nil }
    }

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    func cgImage() -> CGImage? {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Indices (pixel offsets) of the pixels that differ by more than `tolerance` on any channel.
func differingPixels(_ a: Bitmap, _ b: Bitmap, tolerance: Int) -> [Int] {
    var result: [Int] = []
    a.pixels.withUnsafeBufferPointer { pa in
        b.pixels.withUnsafeBufferPointer { pb in
            for i in 0..<(a.width * a.height) {
                let o = i * 4
                if abs(Int(pa[o]) - Int(pb[o])) > tolerance
                    || abs(Int(pa[o + 1]) - Int(pb[o + 1])) > tolerance
                    || abs(Int(pa[o + 2]) - Int(pb[o + 2])) > tolerance
                    || abs(Int(pa[o + 3]) - Int(pb[o + 3])) > tolerance {
                    result.append(i)
                }
            }
        }
    }
    return result
}

/// baseline | current | current dimmed with the differing pixels in red, side by side.
func sideBySide(baseline: Bitmap, current: Bitmap, differing: [Int]) -> Bitmap {
    let gap = 8
    let h = max(baseline.height, current.height)
    var out = Bitmap(width: baseline.width + current.width * 2 + gap * 2, height: h)
    for i in stride(from: 0, to: out.pixels.count, by: 4) {   // magenta gutters show the gaps
        out.pixels[i] = 255; out.pixels[i + 1] = 0; out.pixels[i + 2] = 255; out.pixels[i + 3] = 255
    }
    func blit(_ src: Bitmap, atX x0: Int, dim: Bool) {
        for y in 0..<src.height {
            for x in 0..<src.width {
                let s = (y * src.width + x) * 4
                let d = (y * out.width + x0 + x) * 4
                for c in 0..<3 { out.pixels[d + c] = dim ? UInt8(Int(src.pixels[s + c]) / 3) : src.pixels[s + c] }
                out.pixels[d + 3] = 255
            }
        }
    }
    blit(baseline, atX: 0, dim: false)
    blit(current, atX: baseline.width + gap, dim: false)
    let x2 = baseline.width + current.width + gap * 2
    blit(current, atX: x2, dim: true)
    if baseline.width == current.width && baseline.height == current.height {
        for i in differing {
            let y = i / current.width, x = i % current.width
            let d = (y * out.width + x2 + x) * 4
            out.pixels[d] = 255; out.pixels[d + 1] = 40; out.pixels[d + 2] = 40; out.pixels[d + 3] = 255
        }
    }
    return out
}

func writePNG(_ bitmap: Bitmap, to url: URL) {
    guard let image = bitmap.cgImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Main

var positional: [String] = []
var threshold = 0.5
var tolerance = 16
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--threshold": threshold = args.next().flatMap(Double.init) ?? threshold
    case "--tolerance": tolerance = args.next().flatMap(Int.init) ?? tolerance
    default: positional.append(arg)
    }
}
guard positional.count == 3 else {
    print("usage: snapshot-compare <baseline dir> <current dir> <diff dir> [--threshold %] [--tolerance 0-255]")
    exit(2)
}
let baselineDir = URL(fileURLWithPath: positional[0], isDirectory: true)
let currentDir = URL(fileURLWithPath: positional[1], isDirectory: true)
let diffDir = URL(fileURLWithPath: positional[2], isDirectory: true)
try? FileManager.default.createDirectory(at: diffDir, withIntermediateDirectories: true)

func pngNames(_ dir: URL) -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return Set(names.filter { $0.hasSuffix(".png") })
}

let baselines = pngNames(baselineDir)
let currents = pngNames(currentDir)
var failed: [String] = []

for name in baselines.union(currents).sorted() {
    let label = String(name.dropLast(4))
    guard baselines.contains(name) else {
        print("NEW     \(label) (no baseline: run scripts/snapshot.sh --update)")
        failed.append(label)
        continue
    }
    guard currents.contains(name) else {
        print("MISSING \(label) (not rendered)")
        failed.append(label)
        continue
    }
    guard let base = Bitmap(url: baselineDir.appendingPathComponent(name)),
          let cur = Bitmap(url: currentDir.appendingPathComponent(name)) else {
        print("FAIL    \(label): unreadable PNG")
        failed.append(label)
        continue
    }
    if base.width != cur.width || base.height != cur.height {
        print("FAIL    \(label): size \(cur.width)×\(cur.height), baseline \(base.width)×\(base.height)")
        writePNG(sideBySide(baseline: base, current: cur, differing: []), to: diffDir.appendingPathComponent(name))
        failed.append(label)
        continue
    }
    let differing = differingPixels(base, cur, tolerance: tolerance)
    let percent = 100 * Double(differing.count) / Double(base.width * base.height)
    let shown = String(format: "%.3f %%", percent)
    if percent > threshold {
        print("FAIL    \(label): \(shown) of pixels differ (threshold \(threshold) %)")
        writePNG(sideBySide(baseline: base, current: cur, differing: differing), to: diffDir.appendingPathComponent(name))
        failed.append(label)
    } else {
        print("ok      \(label): \(shown)")
    }
}

if failed.isEmpty {
    print("All \(baselines.count) snapshots match.")
    exit(0)
}
print("\(failed.count) snapshot(s) differ: \(failed.joined(separator: ", "))")
print("Side-by-side images (baseline | current | differences): \(diffDir.path)")
exit(1)
