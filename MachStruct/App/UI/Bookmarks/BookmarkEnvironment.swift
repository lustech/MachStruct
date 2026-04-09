import SwiftUI
import MachStructCore

// MARK: - Bookmarked node IDs (read)

/// The set of currently bookmarked node IDs, injected by `ContentView` so any
/// descendant view can check whether a specific node is bookmarked in O(1).
private struct BookmarkedNodeIDsKey: EnvironmentKey {
    static let defaultValue: Set<NodeID> = []
}

extension EnvironmentValues {
    var bookmarkedNodeIDs: Set<NodeID> {
        get { self[BookmarkedNodeIDsKey.self] }
        set { self[BookmarkedNodeIDsKey.self] = newValue }
    }
}

// MARK: - Toggle bookmark (write)

/// A closure injected by `ContentView` that adds or removes a node ID from
/// the bookmark list.  `nil` means bookmarks are not available in the current
/// context (e.g. while the document is loading).
private struct ToggleBookmarkKey: EnvironmentKey {
    static let defaultValue: ((NodeID) -> Void)? = nil
}

extension EnvironmentValues {
    var toggleBookmark: ((NodeID) -> Void)? {
        get { self[ToggleBookmarkKey.self] }
        set { self[ToggleBookmarkKey.self] = newValue }
    }
}
