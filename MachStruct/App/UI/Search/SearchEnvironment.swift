import SwiftUI
import MachStructCore

// MARK: - Search match IDs environment key

/// The set of row node IDs that match the current search query.
/// Read by `NodeRow` to decide whether to draw a match highlight.
private struct SearchMatchIDsKey: EnvironmentKey {
    static let defaultValue: Set<NodeID> = []
}

extension EnvironmentValues {
    /// All row node IDs that matched the current search query.
    /// Empty when no search is active or the query is empty.
    var searchMatchIDs: Set<NodeID> {
        get { self[SearchMatchIDsKey.self] }
        set { self[SearchMatchIDsKey.self] = newValue }
    }
}

// MARK: - Active match ID environment key

/// The row node ID of the currently focused search match.
/// Read by `NodeRow` to apply the stronger "active match" highlight.
private struct ActiveSearchMatchIDKey: EnvironmentKey {
    static let defaultValue: NodeID? = nil
}

extension EnvironmentValues {
    /// The row node ID of the currently navigated-to match.
    /// Nil when no search is active or there are no results.
    var activeSearchMatchID: NodeID? {
        get { self[ActiveSearchMatchIDKey.self] }
        set { self[ActiveSearchMatchIDKey.self] = newValue }
    }
}
