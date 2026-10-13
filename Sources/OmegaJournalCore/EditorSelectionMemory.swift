import Foundation

/// Editor track (wave 2): where the caret was when an entry's text view went
/// away, so the next text view for the same entry resumes there.
///
/// Zen mode swaps in a separate editor view, and closing/reopening an entry
/// builds a new one; without this every swap dropped the caret to the end of
/// the document, scrolled to the top and lost keyboard focus (Esc then did
/// nothing until the writer clicked back into the text). Only UTF-16 offsets
/// and a focus flag are kept — never text — and only in memory.
public struct EditorSelectionMemory: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var location: Int
        public var length: Int
        public var wasFocused: Bool
        public init(location: Int, length: Int, wasFocused: Bool) {
            self.location = location
            self.length = length
            self.wasFocused = wasFocused
        }
    }

    public private(set) var order: [String] = []
    private var storage: [String: Snapshot] = [:]
    public let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    public mutating func remember(_ snapshot: Snapshot, for key: String) {
        storage[key] = snapshot
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { storage[order.removeFirst()] = nil }
    }

    /// The remembered selection clamped to a text of `textLength` UTF-16 units
    /// (the body may have changed since, e.g. a reader-side task toggle).
    public func restore(for key: String, textLength: Int) -> Snapshot? {
        guard let s = storage[key] else { return nil }
        let len = max(0, textLength)
        let loc = min(max(0, s.location), len)
        let selLen = min(max(0, s.length), len - loc)
        return Snapshot(location: loc, length: selLen, wasFocused: s.wasFocused)
    }

    public mutating func forget(_ key: String) {
        storage[key] = nil
        order.removeAll { $0 == key }
    }
}
