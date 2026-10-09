import Foundation

@main
enum ChatHistoryTests {
    static func main() {
        var executedCaseCount = 0

        func expectMessages(_ name: String, history: [[String: Any]], keepFileContents: Bool = true,
                            expected: [(role: String, content: String)]) {
            let actual = openAICompatibleChatMessages(from: history, keepFileContents: keepFileContents)
            let pairs = actual.map { (role: $0["role"] as? String ?? "?", content: $0["content"] as? String) }
            precondition(pairs.count == expected.count,
                         "\(name): expected \(expected.count) messages, got \(pairs.count): \(actual)")
            for (index, (got, want)) in zip(pairs, expected).enumerated() {
                precondition(got.role == want.role,
                             "\(name) #\(index): expected role \(want.role), got \(got.role)")
                precondition(got.content == want.content,
                             "\(name) #\(index): expected \(String(reflecting: want.content)), got \(String(reflecting: got.content))")
            }
            precondition(actual.allSatisfy { $0.count == 2 },
                         "\(name): messages must carry only role and content")
            executedCaseCount += 1
        }

        // The bug: a first turn sent to Claude with the window context is
        // [context, question]. Keeping only the first block lost the question.
        expectMessages("window context keeps the question", history: [
            ["role": "user", "content": [
                ["type": "text", "text": "Context — App: Safari, Window: Docs, URL: https://example.com"],
                ["type": "text", "text": "Summarise this page"],
            ]],
            ["role": "assistant", "content": [
                ["type": "text", "text": "It explains the API."],
            ]],
        ], expected: [
            ("user", "Context — App: Safari, Window: Docs, URL: https://example.com\n\nSummarise this page"),
            ("assistant", "It explains the API."),
        ])

        expectMessages("image attachment becomes a placeholder", history: [
            ["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="]],
                ["type": "text", "text": "File: shot.png"],
                ["type": "text", "text": "What is in this picture?"],
            ]],
        ], expected: [
            ("user", "[attached image]\n\nFile: shot.png\n\nWhat is in this picture?"),
        ])

        expectMessages("PDF attachment becomes a placeholder", history: [
            ["role": "user", "content": [
                ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": "JVBERi0="]],
                ["type": "text", "text": "File: report.pdf"],
                ["type": "text", "text": "Key figures?"],
            ]],
        ], expected: [
            ("user", "[attached document]\n\nFile: report.pdf\n\nKey figures?"),
        ])

        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
        let converted = openAICompatibleChatMessages(from: [
            ["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]],
                ["type": "text", "text": "Describe"],
            ]],
        ], keepFileContents: true)
        precondition(!(converted.first?["content"] as? String ?? "").contains(base64),
                     "image data must not be inlined as text")
        executedCaseCount += 1

        let textFileTurn: [[String: Any]] = [
            ["role": "user", "content": [
                ["type": "text", "text": inlinedFileContentsPrefix + "let x = 1"],
                ["type": "text", "text": "File: main.swift"],
                ["type": "text", "text": "Any bug?"],
            ]],
        ]
        expectMessages("a local model gets the text file's contents", history: textFileTurn,
                       keepFileContents: true, expected: [
            ("user", "File contents:\nlet x = 1\n\nFile: main.swift\n\nAny bug?"),
        ])
        expectMessages("a cloud provider gets the file name only", history: textFileTurn,
                       keepFileContents: false, expected: [
            ("user", "[attached file]\n\nFile: main.swift\n\nAny bug?"),
        ])
        expectMessages("a question that merely mentions file contents is kept", history: [
            ["role": "user", "content": [["type": "text", "text": "File contents: what does it mean?"]]],
        ], keepFileContents: false, expected: [
            ("user", "File contents: what does it mean?"),
        ])

        // Web search answers: tool blocks dropped, citation fragments joined as is.
        expectMessages("web search answer keeps all text in order", history: [
            ["role": "user", "content": [["type": "text", "text": "Release date?"]]],
            ["role": "assistant", "content": [
                ["type": "text", "text": "Let me look.\n"],
                ["type": "server_tool_use", "id": "srvtoolu_01", "name": "web_search", "input": ["query": "release"]],
                ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_01", "content": [
                    ["type": "web_search_result", "title": "Page", "text": "Search text."],
                ]],
                ["type": "text", "text": "It ships "],
                ["type": "text", "text": "in May.", "citations": [["type": "web_search_result_location", "url": "https://example.com"]]],
            ]],
        ], expected: [
            ("user", "Release date?"),
            ("assistant", "Let me look.\nIt ships in May."),
        ])

        expectMessages("plain string turns pass through", history: [
            ["role": "user", "content": "Context — App: Xcode, Window: main.swift\n\nExplain"],
            ["role": "assistant", "content": "  It's a loop.\n"],
        ], expected: [
            ("user", "Context — App: Xcode, Window: main.swift\n\nExplain"),
            ("assistant", "It's a loop."),
        ])

        expectMessages("mixed history after switching back and forth", history: [
            ["role": "user", "content": [
                ["type": "text", "text": "Context — App: Notes, Window: Ideas"],
                ["type": "text", "text": "First question"],
            ]],
            ["role": "assistant", "content": [["type": "text", "text": "First answer"]]],
            ["role": "user", "content": "Second question"],
            ["role": "assistant", "content": "Second answer"],
            ["role": "user", "content": [["type": "text", "text": "Third question"]]],
        ], expected: [
            ("user", "Context — App: Notes, Window: Ideas\n\nFirst question"),
            ("assistant", "First answer"),
            ("user", "Second question"),
            ("assistant", "Second answer"),
            ("user", "Third question"),
        ])

        expectMessages("turns without text are dropped", history: [
            ["role": "user", "content": [["type": "text", "text": "Search something"]]],
            ["role": "assistant", "content": [
                ["type": "server_tool_use", "id": "x", "name": "web_search"],
            ]],
            ["role": "assistant", "content": ""],
            ["role": "user", "content": [["type": "text", "text": "  "]]],
        ], expected: [
            ("user", "Search something"),
        ])

        expectMessages("empty or whitespace text blocks add no blank lines", history: [
            ["role": "user", "content": [
                ["type": "text", "text": ""],
                ["type": "text", "text": "Question"],
                ["type": "text", "text": " \n "],
            ]],
        ], expected: [
            ("user", "Question"),
        ])

        expectMessages("malformed messages are skipped", history: [
            ["content": "no role"],
            ["role": "user"],
            ["role": "user", "content": 42],
            ["role": "user", "content": "Kept"],
        ], expected: [
            ("user", "Kept"),
        ])

        expectMessages("extra keys are not forwarded", history: [
            ["role": "assistant", "content": [["type": "text", "text": "Hi"]], "stop_reason": "end_turn"],
        ], expected: [
            ("assistant", "Hi"),
        ])

        expectMessages("empty history", history: [], expected: [])

        print("Chat history conversion: \(executedCaseCount) cases passed")
    }
}
