import Foundation

// MARK: - StringTable

/// A thread-safe string intern pool.
///
/// Repeated keys in structured documents (e.g. `"id"`, `"name"`, `"type"` appearing
/// across thousands of JSON objects) can generate tens of thousands of redundant
/// `String` allocations.  `StringTable` ensures that only one canonical instance of
/// each unique key string is kept alive.  All `DocumentNode.key` values produced by
/// the same parse session share backing storage through this table.
///
/// **Memory model:**
/// Swift's small-string optimisation already inlines strings ≤ 15 UTF-8 bytes with
/// no heap allocation.  For these the table eliminates redundant `String` struct
/// construction work.  For longer keys (XML tag names, deep-path components, long
/// YAML mapping keys) it also deduplicates the heap buffer — one allocation per
/// unique key regardless of occurrence count.
///
/// **Thread safety:**
/// Protected by `NSLock` because lazy-materialisation tasks run on multiple
/// concurrent background threads while sharing the same `StructuralIndex`.
public final class StringTable: @unchecked Sendable {

    private var table: [String: String]
    private let lock = NSLock()

    /// Create a table pre-populated with `strings` (e.g. eagerly-parsed
    /// `IndexEntry.key` values from a Foundation-path parse).
    public init(preloading strings: some Sequence<String?> = []) {
        var t = [String: String]()
        for case let s? in strings { t[s] = s }
        table = t
    }

    /// Return the canonical interned instance of `string`.
    ///
    /// If `string` has been seen before, the existing instance is returned so
    /// callers share backing storage.  Otherwise `string` is stored as the
    /// canonical copy and returned.
    ///
    /// Safe to call from any thread.
    public func intern(_ string: String) -> String {
        // Fast read path — acquire lock only if a write might be needed.
        lock.lock()
        defer { lock.unlock() }
        if let existing = table[string] { return existing }
        table[string] = string
        return string
    }

    /// Intern `string` if non-nil, otherwise return `nil`.  Convenience wrapper.
    public func intern(_ string: String?) -> String? {
        guard let s = string else { return nil }
        return intern(s)
    }

    /// Number of unique strings currently held.
    public var count: Int {
        lock.withLock { table.count }
    }
}
