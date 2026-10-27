import Foundation

// MARK: - Loading a large document's rows

/// What a large document's tree must load to show a row, and what it must
/// keep (ADR-002). The tree drills through keys: the row for `"events": [...]`
/// lists the array's elements, so those — not the array — are what opening it
/// needs (#23).
extension NodeIndex {

    /// The node whose children the row for `id` lists: a key's value when it
    /// is a container, or the node itself. `nil` when the row lists nothing,
    /// or the value isn't loaded.
    public func listedContainer(for id: NodeID) -> DocumentNode? {
        guard let node = node(for: id) else { return nil }
        switch node.type {
        case .object, .array:
            return node
        case .keyValue:
            guard let value = node.childIDs.first.flatMap({ self.node(for: $0) }),
                  value.type == .object || value.type == .array else { return nil }
            return value
        case .scalar:
            return nil
        }
    }

    /// The nodes to load so the rows opened at `ids` can list their children,
    /// by the parent they are listed under. A key whose value isn't loaded
    /// asks for the value first. Containers with more than `limit` children
    /// are listed as ranges, which ask for what they show, so they are left
    /// out.
    public func childrenToLoad(opening ids: [NodeID], limit: Int) -> [NodeID: [NodeID]] {
        var request: [NodeID: [NodeID]] = [:]
        for id in ids {
            guard let node = node(for: id) else { continue }
            if node.type == .keyValue, let valueID = node.childIDs.first,
               self.node(for: valueID) == nil {
                request[id, default: []].append(valueID)
                continue
            }
            guard let container = listedContainer(for: id),
                  container.childIDs.count <= limit else { continue }
            let missing = container.childIDs.filter { self.node(for: $0) == nil }
            if !missing.isEmpty { request[container.id, default: []].append(contentsOf: missing) }
        }
        return request
    }

    /// The rows listed under the root and under each of `expandedIDs`, with
    /// the value each key's row shows. Containers with more than `limit`
    /// children are listed as ranges and contribute nothing here.
    public func rowsShown(expandedIDs: Set<NodeID>, limit: Int) -> Set<NodeID> {
        var shown: Set<NodeID> = [rootID]
        for id in expandedIDs.union([rootID]) {
            shown.insert(id)
            if let node = node(for: id), node.type == .keyValue {
                shown.formUnion(node.childIDs)
            }
            guard let container = listedContainer(for: id),
                  container.childIDs.count <= limit else { continue }
            for child in container.childIDs {
                shown.insert(child)
                if let node = node(for: child), node.type == .keyValue {
                    shown.formUnion(node.childIDs)
                }
            }
        }
        return shown
    }
}

extension DocumentSource {

    /// Builds the nodes `request` lists under each parent that `index`
    /// doesn't hold, with the value of each key built too, since a key's row
    /// shows it. Parents not in `index` are skipped.
    public func build(_ request: [NodeID: [NodeID]], in index: NodeIndex) -> [NodeID: DocumentNode] {
        var built = [NodeID: DocumentNode]()
        for (parentID, ids) in request {
            guard let parent = index.node(for: parentID) else { continue }
            for id in ids where index.node(for: id) == nil {
                guard let node = node(for: id, parent: parent) else { continue }
                built[id] = node
                if node.type == .keyValue, let valueID = node.childIDs.first,
                   index.node(for: valueID) == nil,
                   let value = self.node(for: valueID, parent: node) {
                    built[valueID] = value
                }
            }
        }
        return built
    }
}
