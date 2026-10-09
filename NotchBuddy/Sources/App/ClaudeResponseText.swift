import Foundation

/// Extracts the assistant's full text from an Anthropic Messages API content array.
/// Web-search responses interleave text with tool blocks, and citations can
/// split a sentence across adjacent text blocks. Keep the original text and
/// whitespace without inserting separators, then trim only the complete result.
/// Returns nil when the response carries no assistant text at all.
func claudeResponseText(fromContent content: [[String: Any]]) -> String? {
    let text = content.compactMap { block -> String? in
        guard block["type"] as? String == "text" else { return nil }
        return block["text"] as? String
    }
    .joined()
    .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

/// Converts the stored chat history to messages for an OpenAI-compatible
/// provider (Google, OpenAI, Ollama, LM Studio), whose content is a plain string.
/// The history may hold Anthropic content arrays (turns sent while Claude was the
/// provider) or plain strings (turns sent through an OpenAI-compatible provider).
/// A user turn keeps every text block in order (the window or file context, then
/// the question), and an attached image or PDF becomes a short placeholder, since
/// a text-only local model would reject the binary. The contents of a text file
/// sent to Claude are kept only when `keepFileContents` is true (local models,
/// which get them anyway); otherwise they become a placeholder too, as a file's
/// contents only ever go to Anthropic or to a local model. An assistant turn keeps
/// its answer text. Turns left with no text at all are dropped.
func openAICompatibleChatMessages(from history: [[String: Any]],
                                  keepFileContents: Bool) -> [[String: Any]] {
    history.compactMap { message -> [String: Any]? in
        guard let role = message["role"] as? String else { return nil }
        let text: String
        if let plain = message["content"] as? String {
            text = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let blocks = message["content"] as? [[String: Any]] {
            if role == "assistant" {
                text = claudeResponseText(fromContent: blocks) ?? ""
            } else {
                text = blocks.compactMap { openAICompatibleText(ofUserBlock: $0, keepFileContents: keepFileContents) }
                    .joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            return nil
        }
        return text.isEmpty ? nil : ["role": role, "content": text]
    }
}

/// Starts the text block that carries a text file's contents in a Claude turn.
let inlinedFileContentsPrefix = "File contents:\n"

/// One block of a user turn as text: the text itself, or a placeholder for an
/// attachment. Other block types (none are sent today) are left out.
private func openAICompatibleText(ofUserBlock block: [String: Any], keepFileContents: Bool) -> String? {
    switch block["type"] as? String {
    case "text":
        guard let text = block["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if !keepFileContents && text.hasPrefix(inlinedFileContentsPrefix) { return "[attached file]" }
        return text
    case "image":
        return "[attached image]"
    case "document":
        return "[attached document]"
    default:
        return nil
    }
}
