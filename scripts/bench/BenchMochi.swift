// BenchMochi.swift — offline benchmark and frame dumper for the animated Mochi.
// Compile + run via: bash scripts/bench-mochi.sh [--png DIR | --compare DIR_A DIR_B]
//
// It runs BotEngine.update + the same draw sequence as BotCanvasView / MiniBotCanvasView
// for N frames into an offscreen bitmap (2x, like a Retina display) through SwiftUI's
// ImageRenderer, at the compact and the expanded sizes, for a few states.
//
// Time is virtual: CACurrentMediaTime is shadowed below so every run is deterministic
// (BotEngine reads it for tweens, blinks and badge phases). Random behaviour (blinks,
// mini look targets, particle emission) is disabled or replaced by fixed values, so two
// builds of BotEngine produce comparable frames (--png then --compare).

import Foundation
import SwiftUI
import AppKit
import QuartzCore
import ImageIO
import UniformTypeIdentifiers

// MARK: - Virtual clock (shadows QuartzCore's CACurrentMediaTime for this module)

enum VClock {
    nonisolated(unsafe) static var now: Double = 1000
}

func CACurrentMediaTime() -> CFTimeInterval { VClock.now }

// MARK: - Stubs (substitutes for app-only types)

@MainActor
final class SoundEngine {
    static let shared = SoundEngine()
    func play(_ name: String) {}
}

extension Notification.Name {
    static let botDizzy = Notification.Name("notchBuddy.botDizzy")
}

// MARK: - Scenarios

struct Scenario {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let overhang: CGFloat
    var mini = false
    var state: BotState = .idle
    var outfit: Outfit = .none
    var dancing = false
    var rollEvery: Int = 0        // frames between rolls (finished)
    var sparksWithRoll = false
    var heartsEvery: Int = 0      // frames between love emotes (hearts + blush)
    var miniJumpEvery: Int = 0
    var zEvery: Int = 0           // frames between "z" particles (sleeping)
    var waving = false            // greeting hands (expanded only)
    var still = false             // pointer at rest: Mochi keeps looking the same way
}

// BotPlacement: canvas = diameter / 0.6, + 40 pt particle overhang on top.
let compactW: CGFloat = 20 / 0.6            // compact island, diameter 20
let expandedW: CGFloat = 58 / 0.6           // overview, diameter 58
let miniGridW: CGFloat = 12 / 0.6           // compact 2x2 grid of mini Mochis
let miniPillW: CGFloat = 22 / 0.6           // mini Mochi in an agent pill

func scenarios() -> [Scenario] {
    var out: [Scenario] = []
    for (size, w) in [("compact", compactW), ("expanded", expandedW)] {
        let h = w + 40
        out.append(Scenario(name: "\(size)-idle", width: w, height: h, overhang: 40))
        out.append(Scenario(name: "\(size)-working", width: w, height: h, overhang: 40, state: .working))
        out.append(Scenario(name: "\(size)-finished", width: w, height: h, overhang: 40, state: .finished,
                            rollEvery: 90, sparksWithRoll: true))
        out.append(Scenario(name: "\(size)-idle-beanie", width: w, height: h, overhang: 40, outfit: .beanie))
        out.append(Scenario(name: "\(size)-working-crown", width: w, height: h, overhang: 40,
                            state: .working, outfit: .crown))
        out.append(Scenario(name: "\(size)-working-sunglasses", width: w, height: h, overhang: 40,
                            state: .working, outfit: .sunglasses))
        out.append(Scenario(name: "\(size)-dancing", width: w, height: h, overhang: 40, dancing: true))
        out.append(Scenario(name: "\(size)-love", width: w, height: h, overhang: 40, heartsEvery: 120))
        out.append(Scenario(name: "\(size)-sleeping", width: w, height: h, overhang: 40, state: .sleeping,
                            zEvery: 78))
        out.append(Scenario(name: "\(size)-approval", width: w, height: h, overhang: 40, state: .approval))
    }
    out.append(Scenario(name: "expanded-wave", width: expandedW, height: expandedW + 40, overhang: 40,
                        waving: true))
    // The usual compact case: an agent works, the pointer is elsewhere and still.
    out.append(Scenario(name: "compact-working-still", width: compactW, height: compactW + 40, overhang: 40,
                        state: .working, still: true))
    out.append(Scenario(name: "compact-working-beanie-still", width: compactW, height: compactW + 40,
                        overhang: 40, state: .working, outfit: .beanie, still: true))
    out.append(Scenario(name: "compact-working-crown-still", width: compactW, height: compactW + 40,
                        overhang: 40, state: .working, outfit: .crown, still: true))
    out.append(Scenario(name: "mini12-working", width: miniGridW, height: miniGridW, overhang: 0,
                        mini: true, state: .working, miniJumpEvery: 130))
    out.append(Scenario(name: "mini22-idle", width: miniPillW, height: miniPillW, overhang: 0,
                        mini: true, state: .idle, miniJumpEvery: 130))
    return out
}

// MARK: - Deterministic engine setup

/// Small LCG so injected particles are the same in every build.
struct LCG {
    var s: UInt64
    mutating func next() -> CGFloat {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((s >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
}

@MainActor
func injectParticles(_ e: BotEngine, _ type: Particle.ParticleType, count: Int, rng: inout LCG) {
    for i in 0..<count {
        e.particles.append(Particle(
            type: type,
            x: (rng.next() - 0.5) * 0.9, y: -0.7 - rng.next() * 0.2,
            vx: (rng.next() - 0.5) * 0.35, vy: -(0.45 + rng.next() * 0.35),
            age: -Double(i) * 0.14, life: 1.3 + Double(rng.next()) * 0.5,
            rot: rng.next() * .pi * 2, size: 0.15 + rng.next() * 0.08))
    }
}

@MainActor
func makeEngine(_ sc: Scenario) -> BotEngine {
    let e = BotEngine()
    e.t0 = VClock.now - 1.234
    e.lastTime = VClock.now
    e.nextBlink = .infinity              // blinks are triggered on fixed frames instead
    e.lastAmbient = .infinity            // no random ambient particles
    e.miniLookNextTime = .infinity
    e.miniLookTarget = CGPoint(x: 0.4, y: -0.2)
    e.miniNextBehavior = .infinity
    e.isMini = sc.mini
    if sc.mini { e.bodyColor = CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1) }
    e.particleOverhang = sc.overhang
    e.setState(sc.state, force: true)
    // setBadge swaps the badge on a DispatchQueue hop that never runs here: let its
    // fade-out tween end, then show the badge directly.
    VClock.now += 0.1
    e.update(dt: 1.0 / 60)
    e.badge = e.cfg.badge
    e.badgeS = e.badge == nil ? 0 : 1
    if sc.outfit != .none { e.setOutfit(sc.outfit, animated: false) }
    e.setDancing(sc.dancing)
    e.lookX = 0.35
    e.lookY = -0.2
    if sc.mini { e.permanentEmote = .happy }
    if sc.waving { e.hands = 1; e.waveStart = VClock.now; e.waveUntil = VClock.now + 1e6 }
    return e
}

/// Per-frame scripted events (stand in for the random ones of the app).
@MainActor
func scriptedEvents(_ e: BotEngine, _ sc: Scenario, frame: Int, rng: inout LCG) {
    if frame % 170 == 37 { e.blink() }
    // Slow look drift, like a pointer moving around.
    let f = sc.still ? 0 : Double(frame)
    e.lookX = 0.35 * sin(f * 0.013)
    e.lookY = -0.2 + 0.1 * cos(f * 0.009)
    if sc.rollEvery > 0, frame % sc.rollEvery == 5 {
        e.doRoll(duration: 950, turns: 1)
        if sc.sparksWithRoll { injectParticles(e, .spark, count: 5, rng: &rng) }
    }
    if sc.heartsEvery > 0, frame % sc.heartsEvery == 10 {
        // Love emote: heart eyes, blush, hop; its random hearts are swapped for fixed ones.
        let kept = e.particles
        e.triggerEmote(.love, duration: 1.2)
        e.particles = kept
        injectParticles(e, .heart, count: 4, rng: &rng)
    }
    if sc.zEvery > 0, frame % sc.zEvery == 3 { injectParticles(e, .z, count: 1, rng: &rng) }
    if sc.miniJumpEvery > 0, frame % sc.miniJumpEvery == 20 {
        e.doMiniBehaviorLoop()
        e.miniNextBehavior = .infinity
    }
}

// MARK: - The frame, drawn like BotCanvasView / MiniBotCanvasView

@MainActor
func drawFrame(_ engine: BotEngine, context: GraphicsContext, size: CGSize) {
    if engine.isMini {
        var ctx = context
        engine.applyDance(&ctx, size: size)
        engine.draw(context: ctx, size: size)
        return
    }
    var ctx = context
    engine.applyDance(&ctx, size: size)
    if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
        let center = engine.bodyCenter(size: size)
        var rigidCtx = ctx
        rigidCtx.translateBy(x: center.x, y: center.y)
        rigidCtx.rotate(by: .radians(engine.roll))
        rigidCtx.translateBy(x: -center.x, y: -center.y)
        engine.drawHandsBehind(context: rigidCtx, size: size)
        engine.drawOutfitBehind(context: rigidCtx, size: size)
        engine.draw(context: rigidCtx, size: size)
        engine.drawOutfitFront(context: rigidCtx, size: size)
    } else {
        engine.drawHandsBehind(context: ctx, size: size)
        engine.drawOutfitBehind(context: ctx, size: size)
        engine.draw(context: ctx, size: size)
        engine.drawOutfitFront(context: ctx, size: size)
    }
    engine.drawHandsAndExtras(context: ctx, size: size)
}

// MARK: - Offscreen rendering

let scale: CGFloat = 2

@MainActor
final class Offscreen {
    let ctx: CGContext
    let pw: Int, ph: Int
    init(width: CGFloat, height: CGFloat) {
        pw = Int((width * scale).rounded(.up)); ph = Int((height * scale).rounded(.up))
        ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    func render<V: View>(_ view: V) {
        ctx.clear(CGRect(x: 0, y: 0, width: pw, height: ph))
        let r = ImageRenderer(content: view)
        r.scale = scale
        r.render(rasterizationScale: scale) { _, draw in
            self.ctx.saveGState()
            self.ctx.scaleBy(x: scale, y: scale)
            draw(self.ctx)
            self.ctx.restoreGState()
        }
    }
    func writePNG(_ path: String) {
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}

struct MochiFrame: View {
    let engine: BotEngine
    let w, h: CGFloat
    let timer: UnsafeMutablePointer<Double>?
    var body: some View {
        Canvas { context, size in
            let t0 = DispatchTime.now().uptimeNanoseconds
            MainActor.assumeIsolated { drawFrame(engine, context: context, size: size) }
            timer?.pointee += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        }
        .frame(width: w, height: h)
    }
}

struct EmptyFrame: View {
    let w, h: CGFloat
    var body: some View {
        Canvas { _, _ in }.frame(width: w, height: h)
    }
}

// MARK: - Modes

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: " ", count: max(0, n - count)) + self }
}

/// --only a,b,=c: a scenario runs if its name contains a or b, or is exactly c.
func matches(_ name: String, _ filter: String?) -> Bool {
    guard let filter else { return true }
    return filter.split(separator: ",").contains { f in
        f.hasPrefix("=") ? name == f.dropFirst() : name.contains(f)
    }
}

let dt = 1.0 / 60

@MainActor
func runBench(frames: Int, filter: String?) {
    print("scenario".padding(toLength: 30, withPad: " ", startingAt: 0)
          + ["update", "draw", "frame", "net"].map { $0.leftPad(9) }.joined(separator: " "))
    print("  (ms per frame; draw = time inside the Canvas closure, frame = whole ImageRenderer")
    print("   pass at 2x, net = frame minus an empty Canvas of the same size)")
    var emptyCache: [String: Double] = [:]
    for sc in scenarios() where matches(sc.name, filter) {
        VClock.now = 1000
        let off = Offscreen(width: sc.width, height: sc.height)
        let key = "\(sc.width)x\(sc.height)"
        if emptyCache[key] == nil {
            for _ in 0..<30 { off.render(EmptyFrame(w: sc.width, h: sc.height)) }
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<frames { off.render(EmptyFrame(w: sc.width, h: sc.height)) }
            emptyCache[key] = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(frames)
        }
        let e = makeEngine(sc)
        var rng = LCG(s: 42)
        let timer = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        defer { timer.deallocate() }
        var updateMs = 0.0
        var frameMs = 0.0
        let warm = 60
        for f in 0..<(frames + warm) {
            if f == warm { timer.pointee = 0; updateMs = 0; frameMs = 0 }
            VClock.now += dt
            scriptedEvents(e, sc, frame: f, rng: &rng)
            let u0 = DispatchTime.now().uptimeNanoseconds
            e.update(dt: dt)
            let u1 = DispatchTime.now().uptimeNanoseconds
            off.render(MochiFrame(engine: e, w: sc.width, h: sc.height, timer: timer))
            let u2 = DispatchTime.now().uptimeNanoseconds
            updateMs += Double(u1 - u0) / 1e6
            frameMs += Double(u2 - u1) / 1e6
        }
        let n = Double(frames)
        let empty = emptyCache[key]!
        print(sc.name.padding(toLength: 30, withPad: " ", startingAt: 0)
              + [updateMs / n, timer.pointee / n, frameMs / n, frameMs / n - empty]
                .map { String(format: "%.4f", $0).leftPad(9) }.joined(separator: " "))
    }
    for (k, v) in emptyCache.sorted(by: { $0.key < $1.key }) {
        print(String(format: "  empty Canvas %@: %.4f ms", k as NSString, v))
    }
}

/// Frames written for the visual comparison: a spread over the scripted timeline.
let pngFrames: [Int] = [0, 8, 14, 20, 30, 45, 60, 95, 100, 105, 112, 130, 150, 175, 210, 240]

@MainActor
func dumpPNGs(dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var count = 0
    for sc in scenarios() {
        VClock.now = 1000
        let off = Offscreen(width: sc.width, height: sc.height)
        let e = makeEngine(sc)
        var rng = LCG(s: 42)
        let last = pngFrames.max()!
        for f in 0...last {
            VClock.now += dt
            scriptedEvents(e, sc, frame: f, rng: &rng)
            e.update(dt: dt)
            if pngFrames.contains(f) {
                off.render(MochiFrame(engine: e, w: sc.width, h: sc.height, timer: nil))
                off.writePNG("\(dir)/\(sc.name)-\(String(format: "%03d", f)).png")
                count += 1
            }
        }
    }
    print("wrote \(count) frames to \(dir)")
}

func loadRGBA(_ path: String) -> (w: Int, h: Int, px: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (w, h, px) : nil
}

/// Max channel difference and number of pixels that differ by more than 2/255.
func compareDirs(_ a: String, _ b: String) -> Bool {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: a)) ?? [])
        .filter { $0.hasSuffix(".png") }.sorted()
    var worst = 0, identical = 0, totalOver2 = 0
    var report: [String] = []
    for f in files {
        guard let ia = loadRGBA("\(a)/\(f)"), let ib = loadRGBA("\(b)/\(f)"),
              ia.w == ib.w, ia.h == ib.h else { report.append("  \(f): missing or size differs"); worst = 255; continue }
        var maxD = 0, over2 = 0
        for i in stride(from: 0, to: ia.px.count, by: 4) {
            var d = 0
            for c in 0..<4 { d = max(d, abs(Int(ia.px[i + c]) - Int(ib.px[i + c]))) }
            maxD = max(maxD, d)
            if d > 2 { over2 += 1 }
        }
        if maxD == 0 { identical += 1 } else {
            report.append(String(format: "  %@: max diff %d/255, %d of %d px > 2/255",
                                 f as NSString, maxD, over2, ia.w * ia.h))
        }
        worst = max(worst, maxD); totalOver2 += over2
    }
    print("compared \(files.count) frames: \(identical) pixel-identical, worst channel diff \(worst)/255, \(totalOver2) px > 2/255 in total")
    report.forEach { print($0) }
    return files.count > 0
}

// MARK: - Entry point

@main
struct BenchMochi {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let args = Array(CommandLine.arguments.dropFirst())
        MainActor.assumeIsolated {
            if let i = args.firstIndex(of: "--png"), i + 1 < args.count {
                dumpPNGs(dir: args[i + 1])
            } else if let i = args.firstIndex(of: "--compare"), i + 2 < args.count {
                exit(compareDirs(args[i + 1], args[i + 2]) ? 0 : 1)
            } else {
                let frames = args.firstIndex(of: "--frames").flatMap { Int(args[$0 + 1]) } ?? 600
                let filter = args.firstIndex(of: "--only").map { args[$0 + 1] }
                runBench(frames: frames, filter: filter)
            }
        }
    }
}
