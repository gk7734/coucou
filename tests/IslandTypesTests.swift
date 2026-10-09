import Foundation

/// Stand-in for BotEngine's `EyeShape` (SwiftUI file): IslandTypes only stores it.
enum EyeShape: String { case normal }

@main
enum IslandTypesTests {
    static func main() {
        // FNV-1a reference values: fixed across launches, unlike String.hashValue.
        precondition(IslandConst.stableHash("") == 0xcbf2_9ce4_8422_2325)
        precondition(IslandConst.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
        precondition(IslandConst.stableHash("foobar") == 0x85944171f73967e8)

        // Named projects keep their colour, partial matches too.
        precondition(IslandConst.colorForProject("Korus") == "#FF5A4E")
        precondition(IslandConst.colorForProject("  notch-buddy ") == "#EC4899")
        precondition(IslandConst.colorForProject("korus-api") == "#FF5A4E")
        precondition(IslandConst.colorForProject("louisraille.fr-blog") == "#38BDF8")

        // Other projects: one of the fallbacks, always the same for a name.
        let names = ["coucou", "my-app", "api", "", "日本語プロジェクト", String(repeating: "x", count: 500)]
        for name in names {
            let color = IslandConst.colorForProject(name)
            precondition(IslandConst.fallbackColors.contains(color))
            precondition(color == IslandConst.colorForProject(name))
            let expected = IslandConst.fallbackColors[Int(IslandConst.stableHash(name) % 4)]
            precondition(color == expected)
        }
        // The fallbacks are actually spread, not all on one colour.
        let spread = Set((0..<40).map { IslandConst.colorForProject("project-\($0)") })
        precondition(spread.count == IslandConst.fallbackColors.count)

        // Chat height: 240, +40 per message, capped at 300.
        precondition(IslandConst.chatPromptHeight(messageCount: 0) == 240)
        precondition(IslandConst.chatPromptHeight(messageCount: 1) == 280)
        precondition(IslandConst.chatPromptHeight(messageCount: 2) == 300)
        precondition(IslandConst.chatPromptHeight(messageCount: 50) == 300)

        print("Island types: project colours and chat height passed")
    }
}
