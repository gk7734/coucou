#if DEBUG
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Snapshot runs
//
// `Coucou --snapshot <dir> [--only name,name…]` (DEBUG builds only) renders a fixed catalogue
// of island and Settings states (SnapshotCatalogue) to `<dir>/<case>.png` and quits: 0 when
// every case rendered, 1 otherwise, 64 for a bad command line. scripts/snapshot.sh builds,
// runs and compares against tests/snapshots/.
//
// Nothing reaches the screen or the user's data: AppDelegate hands over before any window,
// status item, hook socket, poller, hotkey, audio listener or greeting starts; the views are
// hosted in a borderless window that is never ordered in and are drawn with cacheDisplay;
// UserDefaults is a throwaway suite and the Keychain an empty stand-in (AppDefaults,
// KeychainStore); HookServer reads its agent settings from fixtures in SnapshotMode.home.
// Mochi is a still frame (SnapshotMochi), animations are off, dates are relative to the run
// so every "2m" reads the same.
//
// cacheDisplay, not ImageRenderer: ImageRenderer draws a placeholder for AppKit-backed views
// (text fields, scroll views, Settings' controls) and renders a single pass, before the
// question card's measured height reaches the island. Known capture artifact: cacheDisplay
// draws a hairline at both ends of a capsule's stroke (the overview's agent pills), which the
// app on screen does not show.

/// Knobs the snapshot catalogue turns inside views whose state is private to them.
@MainActor
enum SnapshotScene {
    /// QuestionView opens its "Other…" field for every question.
    static var questionShowsOther = false
}

@MainActor
enum SnapshotFixtures {
    /// Stands in for an IDE's icon (HostAppInfo), which depends on what the Mac has installed.
    static let appIcon: NSImage = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor(srgbRed: 0.16, green: 0.52, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 18, y: 18, width: 28, height: 6), xRadius: 3, yRadius: 3).fill()
        return true
    }
}

/// The window the views are drawn in. Never ordered in, far from every screen, transparent,
/// and always 2× so the PNGs don't depend on the displays plugged in.
private final class SnapshotWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
enum SnapshotRunner {
    static let scale: CGFloat = 2
    /// Behind the island, which is drawn on a transparent panel: a desktop-like grey.
    static let backdrop = CGColor(srgbRed: 0.27, green: 0.29, blue: 0.32, alpha: 1)

    /// Called by AppDelegate instead of the normal launch.
    static func start() {
        NSApp.setActivationPolicy(.prohibited)   // no Dock icon, never active, no menu bar
        Task { @MainActor in
            let code = await run()
            exit(code)
        }
    }

    private static func say(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func run() async -> Int32 {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
            say("usage: Coucou --snapshot <output dir> [--only case,case…]")
            return 64
        }
        let outDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        var only: Set<String>? = nil
        if let j = args.firstIndex(of: "--only"), j + 1 < args.count {
            only = Set(args[j + 1].split(separator: ",").map(String.init))
        }
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            say("snapshot: cannot create \(outDir.path): \(error.localizedDescription)")
            return 1
        }

        BotEngine.frozenDrawTime = 1000
        defer { cleanUp() }

        var failures: [String] = []
        let cases = SnapshotCatalogue.cases.filter { only?.contains($0.name) ?? true }
        if let only, cases.count != only.count {
            let known = Set(SnapshotCatalogue.cases.map(\.name))
            say("snapshot: unknown case(s): \(only.subtracting(known).sorted().joined(separator: ", "))")
            return 64
        }
        for snapshotCase in cases {
            let url = outDir.appendingPathComponent(snapshotCase.name + ".png")
            do {
                let scene = try snapshotCase.make()
                let image = try await render(scene)
                try writePNG(image, to: url)
                say("snapshot: \(snapshotCase.name).png \(image.width)×\(image.height)")
            } catch {
                say("snapshot: \(snapshotCase.name) FAILED: \(error)")
                failures.append(snapshotCase.name)
            }
        }
        if !failures.isEmpty {
            say("snapshot: \(failures.count) case(s) failed: \(failures.joined(separator: ", "))")
            return 1
        }
        return 0
    }

    private static func cleanUp() {
        AppDefaults.store.removePersistentDomain(forName: SnapshotMode.defaultsSuite)
        AppDefaults.store.synchronize()
        // The emptied suite still leaves its (empty) file behind.
        let prefs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(SnapshotMode.defaultsSuite).plist")
        try? FileManager.default.removeItem(at: prefs)
        try? FileManager.default.removeItem(at: SnapshotMode.home)
    }

    // MARK: Render

    struct RenderError: Error, CustomStringConvertible {
        let description: String
    }

    /// Hosts the scene's view offscreen, lets SwiftUI settle (onAppear, measured heights),
    /// then draws it into a 2× bitmap.
    private static func render(_ scene: SnapshotScenePlan) async throws -> CGImage {
        let size = scene.size
        let hosting = NSHostingView(rootView: AnyView(
            scene.view
                .environment(\.locale, Locale(identifier: "en_US"))
                .defaultAppStorage(AppDefaults.store)
                .transaction { t in
                    t.disablesAnimations = true
                    t.animation = nil
                }
        ))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = SnapshotWindow(contentRect: NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        // SwiftUI applies onAppear and measured sizes over a few run-loop turns.
        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(60))
        }
        hosting.layoutSubtreeIfNeeded()

        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: pw * 4, bitsPerPixel: 32) else {
            throw RenderError(description: "no bitmap")
        }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let drawn = rep.cgImage else { throw RenderError(description: "no image") }
        return try compose(drawn, cropToContent: scene.cropToContent)
    }

    /// The drawn view over the backdrop, in sRGB. An island keeps the panel's full width and is
    /// cut 12 pt below the lowest drawn pixel (the panel is 560 pt tall, the island rarely).
    private static func compose(_ drawn: CGImage, cropToContent: Bool) throws -> CGImage {
        let width = drawn.width
        var height = drawn.height
        if cropToContent {
            guard let bottom = lowestOpaqueRow(drawn) else { throw RenderError(description: "nothing drawn") }
            height = min(drawn.height, bottom + 1 + Int(12 * scale))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError(description: "no context")
        }
        ctx.setFillColor(backdrop)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Top rows of the drawing at the top of the (shorter) output.
        ctx.draw(drawn, in: CGRect(x: 0, y: height - drawn.height, width: drawn.width, height: drawn.height))
        guard let image = ctx.makeImage() else { throw RenderError(description: "no output image") }
        return image
    }

    /// Index (from the top) of the lowest row with a visible pixel, nil when all are clear.
    private static func lowestOpaqueRow(_ image: CGImage) -> Int? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The context's first row in memory is the image's top row.
        for row in stride(from: h - 1, through: 0, by: -1) {
            let base = row * w * 4
            for x in 0..<w where pixels[base + x * 4 + 3] > 8 { return row }
        }
        return nil
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError(description: "cannot write \(url.path)")
        }
        let dpi = 72 * scale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi,
                                                 kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError(description: "cannot write \(url.path)") }
    }
}

/// What one case renders: a view at a size, cropped to what it draws or not.
struct SnapshotScenePlan {
    var view: AnyView
    var size: CGSize
    var cropToContent: Bool
}
#endif
