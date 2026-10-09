import Foundation

// HostResolver / ProcessTree (App/HostResolver.swift): which app a session runs in and
// which pill it lands on.

@main @MainActor
enum HostResolverTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func resolve(_ bundle: String = "", term: String = "", emulator: String = "",
                        ancestors: [String] = []) -> HostIdentity? {
        HostResolver.resolve(payloadBundleId: bundle, termProgram: term,
                             terminalEmulator: emulator, ancestorBundleIds: ancestors)
    }

    static func main() {
        print("HostResolver.kind")
        check("VS Code", HostResolver.kind(of: "com.microsoft.VSCode") == .vscode)
        check("VS Code Insiders", HostResolver.kind(of: "com.microsoft.VSCodeInsiders") == .vscode)
        check("Cursor", HostResolver.kind(of: "com.todesktop.230313mzl4w4u92") == .cursor)
        check("iTerm is a terminal", HostResolver.kind(of: "com.googlecode.iterm2") == .terminal)
        check("Zed is an IDE now", HostResolver.kind(of: "dev.zed.Zed") == .ide)
        check("WebStorm is an IDE", HostResolver.kind(of: "com.jetbrains.WebStorm") == .ide)
        check("an editor never seen before is an IDE", HostResolver.kind(of: "app.gram.Gram") == .ide)

        print("HostResolver.resolve — signal order")
        check("process tree wins over the inherited bundle id",
              resolve("com.apple.Terminal", ancestors: ["com.jetbrains.pycharm"]) == HostIdentity(bundleId: "com.jetbrains.pycharm", kind: .ide))
        check("nearest ancestor wins",
              resolve(ancestors: ["com.googlecode.iterm2", "com.jetbrains.WebStorm"])?.bundleId == "com.googlecode.iterm2")
        check("Coucou itself in the tree is skipped",
              resolve(ancestors: ["fr.louisraille.NotchBuddy", "dev.zed.Zed"])?.bundleId == "dev.zed.Zed")
        check("bundle id when the tree has no app (tmux server)",
              resolve("com.mitchellh.ghostty", term: "tmux")?.kind == .terminal)
        check("VS Code by TERM_PROGRAM", resolve(term: "vscode")?.kind == .vscode)
        check("Cursor bundle beats TERM_PROGRAM=vscode",
              resolve("com.todesktop.230313mzl4w4u92", term: "vscode")?.kind == .cursor)
        check("Zed by TERM_PROGRAM", resolve(term: "zed") == HostIdentity(bundleId: "dev.zed.Zed", kind: .ide))
        check("Warp by TERM_PROGRAM", resolve(term: "WarpTerminal")?.bundleId == "dev.warp.Warp-Stable")
        check("JetBrains terminal without bundle id",
              resolve(emulator: "JetBrains-JediTerm") == HostIdentity(bundleId: HostResolver.jetBrainsFallbackId, kind: .ide))
        check("nothing known → nil", resolve(term: "tmux") == nil)
        check("whitespace bundle id is ignored", resolve("  ") == nil)

        print("HostResolver.pillId")
        let ws = HostIdentity(bundleId: "com.jetbrains.WebStorm", kind: .ide)
        check("Claude in VS Code → integration_claude",
              HostResolver.pillId(agent: .claude, host: HostIdentity(bundleId: "com.microsoft.VSCode", kind: .vscode)) == "integration_claude")
        check("Codex in VS Code → integration_claude (pills are per IDE)",
              HostResolver.pillId(agent: .codex, host: HostIdentity(bundleId: "com.microsoft.VSCode", kind: .vscode)) == "integration_claude")
        check("Claude in Cursor → agent_cursor",
              HostResolver.pillId(agent: .claude, host: HostIdentity(bundleId: HostResolver.cursorBundleId, kind: .cursor)) == "agent_cursor")
        check("Claude in WebStorm → ide pill", HostResolver.pillId(agent: .claude, host: ws) == "ide_com-jetbrains-webstorm")
        check("Codex in WebStorm → same ide pill", HostResolver.pillId(agent: .codex, host: ws) == "ide_com-jetbrains-webstorm")
        let iterm = HostIdentity(bundleId: "com.googlecode.iterm2", kind: .terminal)
        check("Claude in a terminal → integration_claude", HostResolver.pillId(agent: .claude, host: iterm) == "integration_claude")
        check("Codex in a terminal → agent_codex", HostResolver.pillId(agent: .codex, host: iterm) == "agent_codex")
        check("Claude with no host → ignored", HostResolver.pillId(agent: .claude, host: nil) == nil)
        check("Codex with no host → agent_codex", HostResolver.pillId(agent: .codex, host: nil) == "agent_codex")

        print("HostResolver.idePillId / names")
        check("slug", HostResolver.idePillId(bundleId: "dev.zed.Zed") == "ide_dev-zed-zed")
        check("runs of symbols collapse", HostResolver.idePillId(bundleId: "a..b__C") == "ide_a-b-c")
        check("empty → unknown", HostResolver.idePillId(bundleId: "...") == "ide_unknown")
        check("isIDEPill", HostResolver.isIDEPill("ide_dev-zed-zed") && !HostResolver.isIDEPill("integration_claude"))
        check("fallback name from bundle id", HostResolver.fallbackName(bundleId: "com.jetbrains.WebStorm") == "WebStorm")
        check("fallback name capitalised", HostResolver.fallbackName(bundleId: "com.jetbrains.pycharm") == "Pycharm")
        check("JetBrains fallback name", HostResolver.fallbackName(bundleId: HostResolver.jetBrainsFallbackId) == "JetBrains")

        print("ProcessTree.ancestors")
        let parents: [Int32: Int32] = [500: 400, 400: 300, 300: 1, 10: 11, 11: 10]
        check("walks to launchd", ProcessTree.ancestors(of: 500) { parents[$0] } == [400, 300])
        check("stops on a loop", ProcessTree.ancestors(of: 10) { parents[$0] } == [11])
        check("missing parent", ProcessTree.ancestors(of: 999) { parents[$0] } == [])
        check("max depth", ProcessTree.ancestors(of: 1000, maxDepth: 3) { $0 + 1 } == [1001, 1002, 1003])

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All tests passed.")
    }
}
