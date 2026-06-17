import Foundation

// MARK: - QueryStore (v2.0 Data Workbench)

/// File-based persistence for jq query history and named saved queries.
///
/// Mirrors `BookmarkStore`: a small JSON file under
/// `<App Support>/MachStruct/queries.json`, read/written on demand.  Unlike
/// bookmarks, queries are **global** (not per-document) — a query written for
/// one file is usually useful for similarly-shaped files.
enum QueryStore {

    /// A user-named saved query.
    struct Saved: Codable, Identifiable, Hashable {
        var id: String { name }
        let name: String
        let query: String
    }

    private struct Persisted: Codable {
        var recent: [String] = []
        var saved: [Saved] = []
    }

    /// Most-recent-first cap so the history menu stays manageable.
    private static let recentLimit = 20

    private static var fileURL: URL? {
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
                .appendingPathComponent("MachStruct", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("queries.json")
        } catch {
            return nil
        }
    }

    private static func read() -> Persisted {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return Persisted() }
        return p
    }

    private static func write(_ p: Persisted) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Recent

    static func recentQueries() -> [String] { read().recent }

    /// Record a successfully-run query at the front of the recents list,
    /// de-duplicating and capping the length.
    static func addRecent(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var p = read()
        p.recent.removeAll { $0 == trimmed }
        p.recent.insert(trimmed, at: 0)
        if p.recent.count > recentLimit { p.recent = Array(p.recent.prefix(recentLimit)) }
        write(p)
    }

    // MARK: Saved

    static func savedQueries() -> [Saved] { read().saved }

    /// Save (or overwrite) a query under `name`.
    static func save(name: String, query: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !q.isEmpty else { return }
        var p = read()
        p.saved.removeAll { $0.name == n }
        p.saved.append(Saved(name: n, query: q))
        p.saved.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        write(p)
    }

    static func deleteSaved(name: String) {
        var p = read()
        p.saved.removeAll { $0.name == name }
        write(p)
    }
}
