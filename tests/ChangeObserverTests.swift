import Foundation
import Observation

/// ChangeObserver, the Observation counterpart of the Combine `$property.sink`s AppState
/// used to feed: delivery after the change is stored, one delivery per main-queue turn,
/// initial/dropFirst, removeDuplicates, debounce, release and cancel.
@MainActor @Observable
final class Model {
    var count = 0
    var name = "a"
    var other = 0
    var optional: Int? = nil
}

@main
enum ChangeObserverTests {
    @MainActor
    static func main() async throws {
        try await deliversStoredValueOnNextTurn()
        try await coalescesOneTurn()
        try await initialAndDropFirst()
        try await removeDuplicates()
        try await watchesOnlyWhatWasRead()
        try await debounce()
        try await releaseAndCancel()
        try await optionalValues()
        print("ChangeObserver: 8 groups passed")
    }

    /// Lets the main queue run what was queued on it.
    @MainActor
    static func settle(_ ms: Int = 30) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    @MainActor
    static func deliversStoredValueOnNextTurn() async throws {
        let m = Model()
        var seen: [(handed: Int, stored: Int)] = []
        let o = ChangeObserver({ m.count }) { value in seen.append((value, m.count)) }
        m.count = 1
        precondition(seen.isEmpty, "delivered synchronously, before the value is stored")
        try await settle()
        precondition(seen.count == 1 && seen[0].handed == 1 && seen[0].stored == 1)
        // Re-armed: the next change is seen too.
        m.count = 2
        try await settle()
        precondition(seen.count == 2 && seen[1].handed == 2)
        _ = o
    }

    @MainActor
    static func coalescesOneTurn() async throws {
        let m = Model()
        var seen: [Int] = []
        let o = ChangeObserver({ m.count }) { seen.append($0) }
        m.count = 1
        m.count = 2
        m.count = 3
        try await settle()
        precondition(seen == [3], "one delivery per turn, with the last value: \(seen)")
        // Unlike @Published, the @Observable macro does not notify when an Equatable
        // property is set to the value it already has.
        m.count = 3
        try await settle()
        precondition(seen == [3], "\(seen)")
        _ = o
    }

    @MainActor
    static func initialAndDropFirst() async throws {
        let m = Model()
        m.count = 7
        var initial: [Int] = []
        let a = ChangeObserver({ m.count }, initial: true) { initial.append($0) }
        precondition(initial == [7], "initial value handed right away")
        var dropped: [Int] = []
        let b = ChangeObserver({ m.count }) { dropped.append($0) }
        precondition(dropped.isEmpty)
        m.count = 8
        try await settle()
        precondition(initial == [7, 8] && dropped == [8])
        _ = (a, b)
    }

    @MainActor
    static func removeDuplicates() async throws {
        let m = Model()
        var seen: [Bool] = []
        // The ServicePollGate shape: map, removeDuplicates, dropFirst.
        let o = ChangeObserver({ m.count > 5 }, removeDuplicates: true) { seen.append($0) }
        m.count = 1   // still false: equal to the baseline
        try await settle()
        precondition(seen.isEmpty, "a value equal to the baseline is skipped")
        m.count = 6
        try await settle()
        m.count = 9   // still true
        try await settle()
        m.count = 0
        try await settle()
        precondition(seen == [true, false], "\(seen)")
        // A custom comparison.
        var names: [String] = []
        let p = ChangeObserver({ m.name }, initial: true,
                               removeDuplicates: { $0.lowercased() == $1.lowercased() }) { names.append($0) }
        m.name = "A"
        try await settle()
        m.name = "b"
        try await settle()
        precondition(names == ["a", "b"], "\(names)")
        _ = (o, p)
    }

    @MainActor
    static func watchesOnlyWhatWasRead() async throws {
        let m = Model()
        var seen = 0
        let o = ChangeObserver({ m.count }) { _ in seen += 1 }
        m.other = 1
        m.name = "z"
        try await settle()
        precondition(seen == 0, "a property that was not read must not call back")
        // Several properties read: a change to any of them calls back.
        var both = 0
        let p = ChangeObserver({ _ = (m.other, m.name) }) { both += 1 }
        m.other = 2
        try await settle()
        m.name = "y"
        try await settle()
        precondition(both == 2)
        _ = (o, p)
    }

    @MainActor
    static func debounce() async throws {
        let m = Model()
        var seen: [Int] = []
        let o = ChangeObserver({ m.count }, initial: true, debounce: 0.3) { seen.append($0) }
        precondition(seen.isEmpty, "the initial value is debounced too")
        try await settle(600)
        precondition(seen == [0])
        // A burst: changes closer than the delay give one delivery, with the last value.
        for i in 1...5 {
            m.count = i
            try await settle(50)
        }
        precondition(seen == [0], "delivered before the burst was over: \(seen)")
        try await settle(700)
        precondition(seen == [0, 5], "\(seen)")
        _ = o
    }

    @MainActor
    static func releaseAndCancel() async throws {
        let m = Model()
        var seen = 0
        var o: ChangeObserver<Int>? = ChangeObserver({ m.count }) { _ in seen += 1 }
        m.count = 1
        o = nil   // released with a change queued
        try await settle()
        m.count = 2
        try await settle()
        precondition(seen == 0 && o == nil, "a released observer must not call back")

        var debounced = 0
        let d = ChangeObserver({ m.count }, debounce: 0.1) { _ in debounced += 1 }
        m.count = 3
        try await settle()
        d.cancel()   // cancelled while the debounce waits
        try await settle(300)
        m.count = 4
        try await settle(300)
        precondition(debounced == 0, "a cancelled observer must not call back")
    }

    @MainActor
    static func optionalValues() async throws {
        let m = Model()
        var seen: [Int?] = []
        // Baseline nil: setting nil again is a duplicate, a value is not.
        let o = ChangeObserver({ m.optional }, removeDuplicates: true) { seen.append($0) }
        m.optional = nil
        try await settle()
        m.optional = 1
        try await settle()
        m.optional = nil
        try await settle()
        precondition(seen == [1, nil], "\(seen)")
        // Initial nil is delivered.
        var first: [Int?] = []
        let p = ChangeObserver({ m.optional }, initial: true, removeDuplicates: true) { first.append($0) }
        precondition(first == [nil])
        _ = (o, p)
    }
}
