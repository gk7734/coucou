import Foundation

@main
enum ClaudeHostTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("ClaudeHost.terminal")
        check("Warp by bundle id", ClaudeHost.terminal(termProgram: "", bundleId: "dev.warp.Warp-Stable")?.name == "Warp")
        check("Warp by TERM_PROGRAM", ClaudeHost.terminal(termProgram: "WarpTerminal", bundleId: "")?.bundleId == "dev.warp.Warp-Stable")
        check("Terminal.app", ClaudeHost.terminal(termProgram: "Apple_Terminal", bundleId: "")?.name == "Terminal")
        check("iTerm", ClaudeHost.terminal(termProgram: "iTerm.app", bundleId: "")?.name == "iTerm")
        check("tmux inside Ghostty: bundle id wins",
              ClaudeHost.terminal(termProgram: "tmux", bundleId: "com.mitchellh.ghostty")?.name == "Ghostty")
        check("cmux: bundle id wins over TERM_PROGRAM=ghostty",
              ClaudeHost.terminal(termProgram: "ghostty", bundleId: "com.cmuxterm.app")?.name == "cmux")
        check("Orca is an IDE, not a terminal", ClaudeHost.terminal(termProgram: "", bundleId: "com.stablyai.orca") == nil)
        check("VS Code → nil", ClaudeHost.terminal(termProgram: "vscode", bundleId: "com.microsoft.VSCode") == nil)
        check("Cursor → nil", ClaudeHost.terminal(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92") == nil)
        check("unknown → nil", ClaudeHost.terminal(termProgram: "", bundleId: "com.example.app") == nil)
        check("Zed is an IDE now, not a terminal (bundle id)",
              ClaudeHost.terminal(termProgram: "", bundleId: "dev.zed.Zed") == nil)
        check("Zed is an IDE now, not a terminal (TERM_PROGRAM)",
              ClaudeHost.terminal(termProgram: "zed", bundleId: "") == nil)
        check("JetBrains is not a terminal",
              ClaudeHost.terminal(termProgram: "", bundleId: "com.jetbrains.WebStorm") == nil)
        print("ClaudeHost follows HostResolver")
        for (id, name) in HostResolver.terminals {
            check("\(name) (\(id)) is a terminal", ClaudeHost.terminal(termProgram: "", bundleId: id)?.name == name
                  && HostResolver.kind(of: id) == .terminal)
        }
        for (term, id) in HostResolver.termPrograms where HostResolver.kind(of: id) == .terminal {
            check("TERM_PROGRAM \(term)", ClaudeHost.terminal(termProgram: term, bundleId: "")?.bundleId == id)
        }

        print("ClaudeHost.name / pillName")
        check("nil host = VS Code", ClaudeHost.name(for: nil) == "VS Code")
        check("Warp host", ClaudeHost.name(for: "dev.warp.Warp-Stable") == "Warp")
        check("unknown host = VS Code", ClaudeHost.name(for: "com.example.app") == "VS Code")
        check("Zed host is no terminal name", ClaudeHost.name(for: "dev.zed.Zed") == "VS Code")
        check("editor session → VS Code", ClaudeHost.pillName(hostApp: nil) == "VS Code")
        check("terminal session → Claude Code", ClaudeHost.pillName(hostApp: "dev.warp.Warp-Stable") == "Claude Code")

        print("ClaudeHost.terminalCardsEnabled")
        UserDefaults.standard.removeObject(forKey: ClaudeHost.terminalCardsKey)
        check("off by default", ClaudeHost.terminalCardsEnabled == false)

        print("ClaudeHost.activate")
        check("an IDE is not activated as a terminal", MainActor.assumeIsolated { !ClaudeHost.activate("com.jetbrains.WebStorm") })
        check("nil host is not activated", MainActor.assumeIsolated { !ClaudeHost.activate(nil) })

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
