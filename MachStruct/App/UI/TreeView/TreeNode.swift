import MachStructCore

// MARK: - TreeNode

/// Adapts a `DocumentNode` + `NodeIndex` into the recursive value type that
/// SwiftUI's `List(data:children:)` needs for lazy tree rendering.
///
/// All computed properties read from the shared `NodeIndex` value — no copies
/// are made and Swift's COW ensures the index is not duplicated across rows.
struct TreeNode: Identifiable {

    let id: NodeID
    let documentNode: DocumentNode

    // Shared reference to the full document index.
    // Passed by value but COW means no actual copy until a mutation happens.
    let nodeIndex: NodeIndex

    init(documentNode: DocumentNode, nodeIndex: NodeIndex) {
        self.id = documentNode.id
        self.documentNode = documentNode
        self.nodeIndex = nodeIndex
    }

    // MARK: - Display helpers

    /// The key to display on the left of this row.
    var displayKey: String? { documentNode.key }

    /// The node whose value should be used for the right-hand display text.
    ///
    /// For `.keyValue` nodes, this is the single child (the actual value node).
    /// For everything else, it is the node itself.
    var valueNode: DocumentNode {
        if documentNode.type == .keyValue,
           let child = nodeIndex.children(of: id).first {
            return child
        }
        return documentNode
    }

    /// Human-readable summary of the value shown on the right side of the row.
    var displayValue: String {
        let vn = valueNode
        switch vn.value {
        case .scalar(let sv):
            return sv.displayText
        case .container(let count):
            return vn.type == .array
                ? "[\(count) \(count == 1 ? "item" : "items")]"
                : "{\(count) \(count == 1 ? "key" : "keys")}"
        case .unparsed:
            // Container or not-yet-parsed — derive a summary from child count.
            let childCount = nodeIndex.children(of: vn.id).count
            if vn.type == .array {
                return "[\(childCount) \(childCount == 1 ? "item" : "items")]"
            } else if vn.type == .object {
                return "{\(childCount) \(childCount == 1 ? "key" : "keys")}"
            }
            return "…"
        case .error(let msg):
            return "⚠ \(msg)"
        }
    }

    /// Badge label and color for the right side of the row.
    var badgeInfo: (label: String, style: BadgeStyle) {
        let vn = valueNode
        switch vn.value {
        case .scalar(let sv):
            return (sv.typeBadge, BadgeStyle(for: sv))
        case .container, .unparsed:
            if vn.type == .array { return ("arr", .arr) }
            if vn.type == .object { return ("obj", .obj) }
            return ("kv", .obj)
        case .error:
            return ("err", .err)
        }
    }

    // MARK: - Children (drives SwiftUI List expand/collapse)

    /// `nil`  → leaf node (no disclosure triangle).
    /// `[]`   → container that is empty (triangle shown, expands to nothing).
    /// `[…]`  → container with children.
    var children: [TreeNode]? {
        switch documentNode.type {
        case .object, .array:
            let kids = nodeIndex.children(of: id)
            return kids.map { TreeNode(documentNode: $0, nodeIndex: nodeIndex) }

        case .keyValue:
            // Drill through the value child to present its children directly,
            // so the UI doesn't show a redundant intermediate row.
            guard let child = nodeIndex.children(of: id).first else { return nil }
            switch child.type {
            case .object, .array:
                let grandkids = nodeIndex.children(of: child.id)
                return grandkids.map { TreeNode(documentNode: $0, nodeIndex: nodeIndex) }
            default:
                return nil  // scalar value — no sub-rows
            }

        case .scalar:
            return nil
        }
    }
}

// MARK: - BadgeStyle

/// Maps node value types to visual badge styles.
enum BadgeStyle {
    case str, int, float, bool, null, obj, arr, err

    init(for sv: ScalarValue) {
        switch sv {
        case .string:  self = .str
        case .integer: self = .int
        case .float:   self = .float
        case .boolean: self = .bool
        case .null:    self = .null
        }
    }
}
