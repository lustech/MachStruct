import SwiftUI
import Foundation
import MachStructCore

// MARK: - BookmarkStore (B2)

/// File-based persistence for per-document bookmark paths.
///
/// Bookmarks live in `<App Support>/MachStruct/bookmarks.json` keyed by file
/// URL path.  Each entry is a list of node-path strings (e.g. `"root.items[0].name"`)
/// produced by `NodeIndex.pathString(to:)`.  On document open `ContentView`
/// loads the paths for that URL and resolves them via `NodeIndex.resolvePath(_:)`;
/// any that don't resolve (because their container hasn't been materialised yet)
/// are dropped silently.
///
/// The store is a value type — it reads the JSON file on each call.  Bookmarks
/// are tiny (a handful per file) so the I/O cost is negligible.
enum BookmarkStore {

    /// `~/Library/Application Support/MachStruct/bookmarks.json` (sandboxed
    /// path under `Containers/.../Application Support/...` when running in
    /// the app sandbox).
    private static var fileURL: URL? {
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
                .appendingPathComponent("MachStruct", isDirectory: true)
            try FileManager.default.createDirectory(at: dir,
                                                    withIntermediateDirectories: true)
            return dir.appendingPathComponent("bookmarks.json")
        } catch {
            return nil
        }
    }

    /// Returns the persisted bookmark paths for the given file URL, or `[]`
    /// when none exist or the store can't be read.
    static func load(for url: URL) -> [String] {
        guard let storeURL = fileURL,
              let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [] }
        return dict[url.path] ?? []
    }

    /// Replace the bookmark path list for the given file URL.  An empty list
    /// removes the entry entirely.
    static func save(_ paths: [String], for url: URL) {
        guard let storeURL = fileURL else { return }
        var dict: [String: [String]] = [:]
        if let data = try? Data(contentsOf: storeURL),
           let existing = try? JSONDecoder().decode([String: [String]].self, from: data) {
            dict = existing
        }
        if paths.isEmpty {
            dict.removeValue(forKey: url.path)
        } else {
            dict[url.path] = paths
        }
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

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
