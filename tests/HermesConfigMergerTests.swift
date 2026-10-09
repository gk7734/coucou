import Foundation

// Tests mergedHermesConfig (NotchBuddy/Sources/App/HermesConfigMerger.swift) — the real
// source, compiled by scripts/test-hermes-config.sh.
//
// Every merged output is also checked to parse as YAML when a python3 with pyyaml is
// found (COUCOU_YAML_PYTHON, then the usual locations); without one, that extra check
// is skipped and the core assertions still run.

@main
enum HermesConfigMergerTests {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var yamlChecked = 0

    static let yamlPython: String? = {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        if let custom = ProcessInfo.processInfo.environment["COUCOU_YAML_PYTHON"], !custom.isEmpty {
            candidates.insert(custom, at: 0)
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["-c", "import yaml"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { continue }
            proc.waitUntilExit()
            if proc.terminationStatus == 0 { return path }
        }
        return nil
    }()

    static func isValidYAML(_ s: String) -> Bool {
        guard let python = yamlPython else { return true }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", "import yaml,sys; yaml.safe_load(sys.stdin)"]
        let input = Pipe()
        proc.standardInput = input
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return false }
        input.fileHandleForWriting.write(Data(s.utf8))
        try? input.fileHandleForWriting.close()
        proc.waitUntilExit()
        yamlChecked += 1
        return proc.terminationStatus == 0
    }

    static func check(_ name: String, _ result: String?, contains: [String] = [], notContains: [String] = [],
                      equals: String? = nil, expectNil: Bool = false) {
        if expectNil {
            precondition(result == nil, "FAIL \(name): expected nil")
            passed += 1
            return
        }
        guard let r = result else { preconditionFailure("FAIL \(name): got nil unexpectedly") }
        precondition(isValidYAML(r), "FAIL \(name): not valid YAML\n---\n\(r)\n---")
        for c in contains {
            precondition(r.contains(c), "FAIL \(name): missing \(c.debugDescription)\n---\n\(r)\n---")
        }
        for nc in notContains {
            precondition(!r.contains(nc), "FAIL \(name): should not contain \(nc.debugDescription)\n---\n\(r)\n---")
        }
        if let equals {
            precondition(r == equals, "FAIL \(name): got\n---\n\(r)\n---\nexpected\n---\n\(equals)\n---")
        }
        passed += 1
    }

    static func occurrences(_ needle: String, in s: String?) -> Int {
        (s ?? "").components(separatedBy: needle).count - 1
    }

    static func main() {
        // 1. Empty file → adds plugins.enabled.coucou
        check("1. empty file", mergedHermesConfig("", enableApprovals: false),
              equals: "\nplugins:\n  enabled:\n    - coucou")

        // 2. plugins: exists but no enabled: → adds enabled with coucou
        check("2. plugins without enabled", mergedHermesConfig("plugins:\n  disabled: []\n", enableApprovals: false),
              equals: "plugins:\n  enabled:\n    - coucou\n  disabled: []\n")

        // 3. plugins.enabled with other item → adds coucou
        check("3. plugins.enabled other items", mergedHermesConfig("plugins:\n  enabled:\n    - other\n", enableApprovals: false),
              equals: "plugins:\n  enabled:\n    - coucou\n    - other\n")

        // 4. coucou already in plugins.enabled → no duplicate
        let case4 = mergedHermesConfig("plugins:\n  enabled:\n    - coucou\n", enableApprovals: false)
        check("4. coucou already present", case4, equals: "plugins:\n  enabled:\n    - coucou\n")

        // 5. enabled: [] (empty inline list) → expands to block list with coucou
        check("5. enabled: []", mergedHermesConfig("plugins:\n  enabled: []\n", enableApprovals: false),
              contains: ["- coucou"], notContains: ["enabled: []"])

        // 6. enabled: [other] inline list → adds coucou to inline list
        check("6. enabled: [other]", mergedHermesConfig("plugins:\n  enabled: [other]\n", enableApprovals: false),
              equals: "plugins:\n  enabled: [other, coucou]\n")

        // 7. Another section with its own enabled: key → only modifies under plugins:
        let case7 = """
        features:
          enabled: [x]
        plugins:
          enabled:
            - existing
        """
        check("7. another section's enabled: untouched", mergedHermesConfig(case7, enableApprovals: false),
              contains: ["features:", "enabled: [x]", "- coucou"])

        // 8. coucou in disabled: → still adds to enabled:
        check("8. coucou in disabled (before enabled)",
              mergedHermesConfig("plugins:\n  disabled:\n    - coucou\n  enabled:\n    - other\n", enableApprovals: false),
              equals: "plugins:\n  disabled:\n    - coucou\n  enabled:\n    - coucou\n    - other\n")
        // 8b. …and when disabled: comes after enabled:, its items are not read as enabled's.
        let case8b = mergedHermesConfig("plugins:\n  enabled:\n    - other\n  disabled:\n    - coucou\n", enableApprovals: false)
        check("8b. coucou in disabled (after enabled)", case8b,
              equals: "plugins:\n  enabled:\n    - coucou\n    - other\n  disabled:\n    - coucou\n")

        // 9. security: without approval: → adds approval with transport keys
        check("9. security without approval", mergedHermesConfig("security:\n  allow_private_urls: false\n", enableApprovals: true),
              equals: "security:\n  approval:\n    transport: coucou\n    transport_fallback: builtin\n  allow_private_urls: false\n\nplugins:\n  enabled:\n    - coucou")

        // 10a. Disabling approvals removes Coucou's transport keys, keeps the plugin entry
        let case10a = """
        plugins:
          enabled:
            - coucou
            - other
        security:
          approval:
            transport: coucou
            transport_fallback: builtin
        """
        check("10a. disable approvals", mergedHermesConfig(case10a, enableApprovals: false),
              contains: ["- coucou", "- other", "approval:"],
              notContains: ["transport: coucou", "transport_fallback: builtin"])

        // 10b. Only Coucou's transport keys go
        check("10b. disable approvals: only ours removed",
              mergedHermesConfig("security:\n  approval:\n    transport: coucou\n    transport_fallback: builtin\n    timeout: 60\n",
                                 enableApprovals: false),
              contains: ["timeout: 60"], notContains: ["transport: coucou", "transport_fallback: builtin"])

        // 11. Flow maps, anchors, multi-document → nil (the user edits by hand)
        check("11. flow map", mergedHermesConfig("{plugins: {enabled: [coucou]}}", enableApprovals: false), expectNil: true)
        check("11b. anchor", mergedHermesConfig("base: &b\n  x: 1\n", enableApprovals: false), expectNil: true)
        check("11c. multi-document", mergedHermesConfig("a: 1\n---\nb: 2\n", enableApprovals: false), expectNil: true)

        // 12. 4-space indentation → uses 4 spaces
        let base12 = """
        model: gpt-4
        plugins:
            enabled:
                - other
        """
        check("12. 4-space indent", mergedHermesConfig(base12, enableApprovals: false),
              equals: "model: gpt-4\nplugins:\n    enabled:\n        - coucou\n        - other")

        // 13. Enable approvals on an empty file: adds both transport keys
        check("13. enableApprovals on empty", mergedHermesConfig("", enableApprovals: true),
              contains: ["transport: coucou", "transport_fallback: builtin"])

        // 14. security.approval already has transport → update, not duplicate
        let case14 = """
        security:
          approval:
            transport: terminal
            transport_fallback: deny
        """
        let r14 = mergedHermesConfig(case14, enableApprovals: true)
        check("14. existing transport updated", r14,
              contains: ["transport: coucou", "transport_fallback: builtin"],
              notContains: ["transport: terminal", "transport_fallback: deny"])
        precondition(occurrences("transport: coucou", in: r14) == 1, "14: one transport line")

        // 15. A sibling of approval: with its own transport key is not touched
        let case15 = """
        security:
          approval:
            mode: manual
          webhooks:
            transport: https
        """
        check("15. sibling transport untouched", mergedHermesConfig(case15, enableApprovals: true),
              contains: ["  approval:\n    transport: coucou\n    transport_fallback: builtin\n    mode: manual",
                         "  webhooks:\n    transport: https"])

        // 16. A block list written at the key's own indentation keeps that indentation
        check("16. list items at the key's indentation",
              mergedHermesConfig("plugins:\n  enabled:\n  - other\n", enableApprovals: false),
              equals: "plugins:\n  enabled:\n  - coucou\n  - other\n")

        // 17. Merging twice changes nothing more
        let once = mergedHermesConfig("model: x\nsecurity:\n  approval:\n    mode: manual\n", enableApprovals: true)
        let twice = once.flatMap { mergedHermesConfig($0, enableApprovals: true) }
        check("17. idempotent", twice, equals: once)

        // ── Which Python runs Hermes (approval transport detection) ──────────────
        let interpreters: [(String, String?)] = [
            ("#!/usr/bin/env python3\nimport sys\n", "python3"),
            ("#!/Users/me/.hermes/venv/bin/python3.11\n", "/Users/me/.hermes/venv/bin/python3.11"),
            // Hermes' installer: a bash launcher that execs its venv
            ("#!/usr/bin/env bash\nunset PYTHONPATH\nunset PYTHONHOME\nexec \"/Users/me/.hermes/hermes-agent/venv/bin/python\" \"/Users/me/.hermes/hermes-agent/hermes\" \"$@\"\n",
             "/Users/me/.hermes/hermes-agent/venv/bin/python"),
            ("#!/bin/sh\n  exec /opt/venv/bin/python3 -m hermes \"$@\"\n", "/opt/venv/bin/python3"),
            ("#!/bin/bash\nexec node cli.js\n", nil),
            ("\u{7F}ELF binary", nil),
            ("", nil),
        ]
        for (launcher, expected) in interpreters {
            precondition(hermesInterpreter(fromExecutable: launcher) == expected,
                         "FAIL interpreter for \(launcher.debugDescription): \(String(describing: hermesInterpreter(fromExecutable: launcher)))")
            passed += 1
        }

        let yamlNote = yamlPython == nil
            ? "YAML validation skipped (no python3 with pyyaml; set COUCOU_YAML_PYTHON)"
            : "\(yamlChecked) outputs validated as YAML"
        print("Hermes config merger: \(passed) cases passed — \(yamlNote)")
    }
}
