import Foundation

// AppLog: background writes, permissions, 1 MB rotation, a file deleted while open,
// appends from many threads. Uses a temporary directory, never ~/Library/Logs.

@main
enum AppLogTests {

    nonisolated(unsafe) static var failures = 0

    static func check(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
    }

    static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? -1
    }

    static func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-applog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        print("AppLog — first line creates the directory and the file")
        do {
            let dir = root.appendingPathComponent("Logs/NotchBuddy")
            let log = AppLog(directory: dir)
            log.append("nb.log", "hello")
            log.append("nb.log", "bell \u{07} esc \u{1B}[31m", timestampFormat: "HH:mm:ss")
            log.flush()
            let file = dir.appendingPathComponent("nb.log")
            check("directory is 0700", mode(dir) == 0o700)
            check("file is 0600", mode(file) == 0o600)
            let l = lines(file)
            check("two lines", l.count == 2)
            check("default timestamp then message",
                  l.first?.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} hello$"#, options: .regularExpression) != nil)
            check("custom timestamp, control characters escaped",
                  l.last?.range(of: #"^\d{2}:\d{2}:\d{2} bell \\u0007 esc \\u001B\[31m$"#, options: .regularExpression) != nil)
        }

        print("AppLog — existing directory and file get their permissions fixed")
        do {
            let dir = root.appendingPathComponent("loose")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o755])
            let file = dir.appendingPathComponent("github.log")
            FileManager.default.createFile(atPath: file.path, contents: Data("old line\n".utf8),
                                           attributes: [.posixPermissions: 0o644])
            let log = AppLog(directory: dir)
            log.append("github.log", "new line")
            log.flush()
            check("directory now 0700", mode(dir) == 0o700)
            check("file now 0600", mode(file) == 0o600)
            let l = lines(file)
            check("appended after the existing line", l.count == 2 && l[0] == "old line" && l[1].hasSuffix(" new line"))
        }

        print("AppLog — rotation at 1 MB")
        do {
            let dir = root.appendingPathComponent("rotate")
            let log = AppLog(directory: dir)
            check("limit is 1 MB", log.maxBytes == 1_048_576)
            let file = dir.appendingPathComponent("n8n.log")
            let filler = String(repeating: "x", count: 1000)
            // Fill to the limit, then one more line rotates.
            var i = 0
            while size(file) < 1_048_576 { log.append("n8n.log", "\(i) \(filler)"); i += 1; log.flush() }
            let before = size(file)
            log.append("n8n.log", "after rotation")
            log.flush()
            let l = lines(file)
            check("was at least 1 MB before (\(before) bytes)", before >= 1_048_576)
            check("rotated: only the new line left", l.count == 1 && l[0].hasSuffix(" after rotation"))
            check("rotated file is 0600", mode(file) == 0o600)
            log.append("n8n.log", "next")
            log.flush()
            check("later lines append to the new file", lines(file).count == 2)
        }

        print("AppLog — file deleted while open is recreated")
        do {
            let dir = root.appendingPathComponent("deleted")
            let log = AppLog(directory: dir)
            let file = dir.appendingPathComponent("nb.log")
            log.append("nb.log", "one")
            log.flush()
            try? FileManager.default.removeItem(at: dir)
            log.append("nb.log", "two")
            log.flush()
            let l = lines(file)
            check("new file with the new line", l.count == 1 && l[0].hasSuffix(" two"))
            check("directory recreated 0700, file 0600", mode(dir) == 0o700 && mode(file) == 0o600)
        }

        print("AppLog — appends from many threads")
        do {
            let dir = root.appendingPathComponent("threads")
            let log = AppLog(directory: dir)
            DispatchQueue.concurrentPerform(iterations: 2000) { n in
                log.append(n % 2 == 0 ? "a.log" : "b.log", "line \(n)")
            }
            log.flush()
            let a = lines(dir.appendingPathComponent("a.log")), b = lines(dir.appendingPathComponent("b.log"))
            check("every line written once", a.count == 1000 && b.count == 1000)
            let numbers = Set((a + b).compactMap { $0.split(separator: " ").last.flatMap { Int($0) } })
            check("no line lost or mixed", numbers == Set(0..<2000))
        }

        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) failed."); exit(1)
    }
}
