import Foundation

/// The file diff of an Edit, MultiEdit or Write tool call, read from a PostToolUse hook payload.
///
/// `Request` copies what the diff needs out of the untyped payload, so it can cross to the
/// background queue; `compute()` gives the same FileDiff for HookServer (the live diff step)
/// and TurnRecorder (the iPhone's last turn), computed once per event.
enum HookFileDiff {

    struct Request: Sendable {
        enum Edit: Sendable {
            case replace([EditPair])      // Edit (one pair), MultiEdit (each pair in order)
            case write(content: String)   // Write: a new file
        }
        struct EditPair: Sendable {
            let old: String
            let new: String
        }

        let path: String
        let edit: Edit
        let isMultiEdit: Bool

        /// Nil when the tool isn't a file edit or the payload lacks what the diff needs.
        init?(tool: String, input: [String: Any]) {
            guard let path = input["file_path"] as? String else { return nil }
            switch tool {
            case "Edit":
                guard let old = input["old_string"] as? String,
                      let new = input["new_string"] as? String else { return nil }
                edit = .replace([EditPair(old: old, new: new)])
                isMultiEdit = false
            case "MultiEdit":
                guard let edits = input["edits"] as? [[String: Any]] else { return nil }
                edit = .replace(edits.compactMap { item in
                    guard let old = item["old_string"] as? String,
                          let new = item["new_string"] as? String else { return nil }
                    return EditPair(old: old, new: new)
                })
                isMultiEdit = true
            case "Write":
                guard let content = input["content"] as? String else { return nil }
                edit = .write(content: content)
                isMultiEdit = false
            default:
                return nil
            }
            self.path = path
        }

        /// The text to diff, in UTF-8 bytes.
        var byteCount: Int {
            switch edit {
            case .replace(let pairs): return pairs.reduce(0) { $0 + $1.old.utf8.count + $1.new.utf8.count }
            case .write(let content): return content.utf8.count
            }
        }

        /// Small enough to diff right where the event is handled: under this size even two
        /// unrelated texts take well under a millisecond, so the queue hop isn't worth it.
        static let inlineLimit = 16 * 1024
        var isSmall: Bool { byteCount <= Self.inlineLimit }

        /// The diff, unfiltered (a no-op edit gives a diff with nothing added or removed).
        func compute() -> FileDiff {
            switch edit {
            case .write(let content):
                return DiffEngine.fromNew(content: content, path: path)
            case .replace(let pairs) where !isMultiEdit:
                let pair = pairs[0]
                return DiffEngine.fromEdit(old: pair.old, new: pair.new, path: path)
            case .replace(let pairs):
                var added = 0, removed = 0, hunks: [DiffHunk] = [], tooLarge = false
                for pair in pairs {
                    let d = DiffEngine.fromEdit(old: pair.old, new: pair.new, path: path)
                    added += d.added; removed += d.removed
                    hunks += d.hunks
                    tooLarge = tooLarge || d.tooLarge
                }
                return FileDiff(path: path, added: added, removed: removed, hunks: hunks,
                                tooLarge: tooLarge, isNewFile: false)
            }
        }

        /// Computes the diff on a background queue and hands it to `completion` on the main
        /// queue. Nonisolated, so neither closure inherits the caller's main-actor isolation
        /// (a main-actor closure run on another queue traps under Swift 6).
        nonisolated func compute(then completion: @escaping @MainActor @Sendable (FileDiff) -> Void) {
            let request = self
            HookFileDiff.queue.async {
                let diff = request.compute()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(diff) }
                }
            }
        }
    }

    /// One serial queue: HookServer holds later events behind a pending diff, so at most one
    /// diff is in flight anyway.
    fileprivate static let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.hook-diff",
                                                 qos: .userInitiated)

    /// The live-diff step for a session: nil when the edit changed nothing.
    static func shown(_ diff: FileDiff) -> FileDiff? {
        (diff.added > 0 || diff.removed > 0) ? diff : nil
    }
}
