import Foundation

// AutoMainPill (App/AutoMainPill.swift): which workspace pill the "Auto" main pill shows,
// and when it moves from one IDE to another.

@main @MainActor
enum AutoMainPillTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let workspace: Set<String> = ["integration_claude", "agent_cursor", "agent_antigravity", "agent_codex"]
    static let orcaBundle = "com.stablyai.orca"
    static let orca = HostResolver.idePillId(bundleId: orcaBundle)   // ide_com-stablyai-orca
    static let webstorm = HostResolver.idePillId(bundleId: "com.jetbrains.WebStorm")

    static func resolve(explicit: String? = nil, last: String? = nil, bundle: String? = nil,
                        catalog: Set<String> = workspace) -> String {
        AutoMainPill.resolve(explicit: explicit, lastActive: last, lastActiveBundleId: bundle,
                             catalogWorkspaceIds: catalog, fallback: "integration_claude")
    }

    /// Plays events through shouldSwitch, as AppState does; `busy` says which pills have a
    /// session working or waiting. Returns the last active pill after each event.
    static func play(_ events: [(pill: String, event: String)], busy: Set<String>,
                     start: String? = nil) -> [String?] {
        var current = start
        var trail: [String?] = []
        for e in events {
            if let activity = AutoMainPill.activity(forEvent: e.event),
               AutoMainPill.shouldSwitch(current: current, to: e.pill, activity: activity,
                                         currentIsBusy: current.map(busy.contains) ?? false) {
                current = e.pill
            }
            trail.append(current)
        }
        return trail
    }

    static func main() {
        print("AutoMainPill.activity")
        check("a prompt is the user's", AutoMainPill.activity(forEvent: "UserPromptSubmit") == .userPrompt)
        check("tool use is the agent's", AutoMainPill.activity(forEvent: "PreToolUse") == .agent)
        check("tool result is the agent's", AutoMainPill.activity(forEvent: "PostToolUse") == .agent)
        check("failed tool is the agent's", AutoMainPill.activity(forEvent: "PostToolUseFailure") == .agent)
        check("SessionEnd doesn't count", AutoMainPill.activity(forEvent: "SessionEnd") == nil)
        check("SessionStart doesn't count", AutoMainPill.activity(forEvent: "SessionStart") == nil)
        check("Stop doesn't count", AutoMainPill.activity(forEvent: "Stop") == nil)
        check("Notification doesn't count", AutoMainPill.activity(forEvent: "Notification") == nil)

        print("AutoMainPill.isWorkspacePill")
        check("Claude Code pill", AutoMainPill.isWorkspacePill("integration_claude", catalogWorkspaceIds: workspace))
        check("an IDE pill", AutoMainPill.isWorkspacePill(orca, catalogWorkspaceIds: workspace))
        check("an agent pill is not", !AutoMainPill.isWorkspacePill("agent_gemini", catalogWorkspaceIds: workspace))
        check("a service pill is not", !AutoMainPill.isWorkspacePill("integration_github", catalogWorkspaceIds: workspace))

        print("AutoMainPill.shouldSwitch")
        check("first activity anywhere sets it",
              AutoMainPill.shouldSwitch(current: nil, to: orca, activity: .agent, currentIsBusy: false))
        check("same pill: nothing to do",
              !AutoMainPill.shouldSwitch(current: orca, to: orca, activity: .userPrompt, currentIsBusy: false))
        check("a prompt elsewhere moves it, even while the current one is busy",
              AutoMainPill.shouldSwitch(current: orca, to: "integration_claude", activity: .userPrompt, currentIsBusy: true))
        check("agent activity elsewhere doesn't while the current one is busy",
              !AutoMainPill.shouldSwitch(current: orca, to: "integration_claude", activity: .agent, currentIsBusy: true))
        check("agent activity elsewhere does when the current one has nothing going on",
              AutoMainPill.shouldSwitch(current: orca, to: "integration_claude", activity: .agent, currentIsBusy: false))

        print("Two IDEs at once (no flip-flop)")
        let interleaved: [(pill: String, event: String)] = [
            (orca, "UserPromptSubmit"), (orca, "PreToolUse"),
            ("integration_claude", "PreToolUse"), (orca, "PostToolUse"),
            ("integration_claude", "PostToolUse"), (orca, "PreToolUse"),
            ("integration_claude", "PreToolUse"),
        ]
        check("agents of both IDEs working: stays on the one the user prompted",
              play(interleaved, busy: [orca, "integration_claude"]).allSatisfy { $0 == orca })
        let trail = play([(orca, "UserPromptSubmit"), (webstorm, "PreToolUse"),
                          (webstorm, "UserPromptSubmit"), (orca, "PreToolUse"), (orca, "PostToolUse")],
                         busy: [orca, webstorm])
        check("the user prompts in WebStorm: moves there, and Orca's tools don't pull it back",
              trail == [orca, orca, webstorm, webstorm, webstorm])
        check("Orca finished: WebStorm's agent takes it on its next tool use",
              play([(webstorm, "PreToolUse")], busy: [webstorm], start: orca) == [webstorm])
        check("SessionEnd on another IDE never moves it",
              play([(webstorm, "SessionEnd")], busy: [], start: orca) == [orca])

        print("AutoMainPill.resolve")
        check("nothing active yet: fallback", resolve() == "integration_claude")
        check("explicit pick wins", resolve(explicit: "agent_cursor", last: orca, bundle: orcaBundle) == "agent_cursor")
        check("explicit pick missing from this build: auto",
              resolve(explicit: "agent_codex", last: "agent_cursor", catalog: ["integration_claude", "agent_cursor"]) == "agent_cursor")
        check("unknown explicit value: auto", resolve(explicit: "integration_github", last: "agent_cursor") == "agent_cursor")
        check("auto: last catalog pill", resolve(last: "agent_codex") == "agent_codex")
        check("auto: last IDE pill with its bundle id", resolve(last: orca, bundle: orcaBundle) == orca)
        check("auto: IDE pill without a bundle id can't be shown",
              resolve(last: orca, bundle: nil) == "integration_claude")
        check("auto: IDE pill with another IDE's bundle id is stale",
              resolve(last: orca, bundle: "com.jetbrains.WebStorm") == "integration_claude")
        check("auto: last pill no longer in this build (App Store has no Codex)",
              resolve(last: "agent_codex", catalog: ["integration_claude", "agent_cursor"]) == "integration_claude")
        check("auto: a non-workspace pill is ignored", resolve(last: "agent_gemini") == "integration_claude")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All AutoMainPill tests passed.")
    }
}
