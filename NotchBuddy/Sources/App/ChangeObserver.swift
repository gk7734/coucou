import Foundation
import Observation

// MARK: - ChangeObserver
//
// Calls back when what `read` reads from an @Observable object (AppState) changes:
// the Observation counterpart of a Combine `$property.sink`, for code that is not a view.
//
// - `read` runs inside withObservationTracking: the properties it touches are the ones
//   watched, and the value it returns is what `onChange` is handed.
// - Delivery is on the next turn of the main queue, once the change is stored (a
//   @Published sink ran before the property was set). Every change made in the same
//   turn is delivered once, with the value read after the last one.
// - `initial`: hand the current value right away (a Combine sink on a @Published does);
//   false is `dropFirst()`, the current value then only being the baseline for
//   `removeDuplicates`.
// - `debounce`: wait until nothing changed for that long, then deliver the latest value
//   (Combine's `debounce`). The initial value is debounced too, as it was.
// - `removeDuplicates`: skip a value equal to the last one delivered (or to the baseline).
// - Stops when the observer is released (like an AnyCancellable) or `cancel()`ed.
//
// Everything runs on the main actor. The only closure that may run elsewhere is
// Observation's change handler, made in a nonisolated function so it carries no actor
// isolation (Swift 6 traps when a closure formed on the main actor runs off it): it only
// hops to the main queue.

@MainActor
final class ChangeObserver<Value> {
    private let read: @MainActor () -> Value
    private let debounce: TimeInterval
    private let isDuplicate: ((Value, Value) -> Bool)?
    private let onChange: @MainActor (Value) -> Void

    private var last: Value?
    private var latest: Value?
    private var pending: DispatchWorkItem?
    private var cancelled = false

    init(_ read: @escaping @MainActor () -> Value,
         initial: Bool = false,
         debounce: TimeInterval = 0,
         removeDuplicates isDuplicate: ((Value, Value) -> Bool)? = nil,
         onChange: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.debounce = debounce
        self.isDuplicate = isDuplicate
        self.onChange = onChange
        let value = track()
        if initial {
            if debounce > 0 { schedule(value) } else { deliver(value) }
        } else {
            last = value
        }
    }

    /// Stops calling back (also done by releasing the observer).
    func cancel() {
        cancelled = true
        pending?.cancel()
        pending = nil
    }

    // MARK: Private

    /// Reads the value and watches what it read, for one change.
    private func track() -> Value {
        withObservationTracking({ read() }, onChange: Self.changeHandler(for: self))
    }

    /// Observation calls this on the thread that made the change, before the value is stored.
    private nonisolated static func changeHandler(for observer: ChangeObserver) -> @Sendable () -> Void {
        let ref = WeakRef(observer)
        return {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ref.value?.changed() }
            }
        }
    }

    private func changed() {
        guard !cancelled else { return }
        let value = track()
        if debounce > 0 { schedule(value) } else { deliver(value) }
    }

    private func schedule(_ value: Value) {
        latest = value
        pending?.cancel()
        let ref = WeakRef(self)
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { ref.value?.deliverLatest() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func deliverLatest() {
        pending = nil
        guard let value = latest else { return }
        latest = nil
        deliver(value)
    }

    private func deliver(_ value: Value) {
        guard !cancelled else { return }
        if let isDuplicate, let last, isDuplicate(last, value) { return }
        last = value
        onChange(value)
    }
}

extension ChangeObserver where Value: Equatable {
    /// Same, skipping a value equal to the last one when `removeDuplicates` is true.
    convenience init(_ read: @escaping @MainActor () -> Value,
                     initial: Bool = false,
                     debounce: TimeInterval = 0,
                     removeDuplicates: Bool,
                     onChange: @escaping @MainActor (Value) -> Void) {
        let isDuplicate: ((Value, Value) -> Bool)? = removeDuplicates ? { (a: Value, b: Value) in a == b } : nil
        self.init(read, initial: initial, debounce: debounce,
                  removeDuplicates: isDuplicate, onChange: onChange)
    }
}

/// A weak reference that can cross to the main queue: only dereferenced there.
private struct WeakRef<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?
    init(_ value: Object) { self.value = value }
}
