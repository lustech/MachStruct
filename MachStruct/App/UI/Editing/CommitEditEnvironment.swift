import SwiftUI
import MachStructCore

// MARK: - CommitEdit Environment Key

/// An environment-injectable closure that commits an `EditTransaction` to the
/// current document.  Set by `ContentView` once the document and undo manager
/// are both available.  Read by `NodeRow` (and any other editing view) without
/// needing a direct reference to `StructDocument` or `UndoManager`.
private struct CommitEditKey: EnvironmentKey {
    static let defaultValue: ((EditTransaction) -> Void)? = nil
}

extension EnvironmentValues {
    /// Call this closure to commit an edit and register it for undo/redo.
    var commitEdit: ((EditTransaction) -> Void)? {
        get { self[CommitEditKey.self] }
        set { self[CommitEditKey.self] = newValue }
    }
}

// MARK: - SerializeNode Environment Key

/// An environment-injectable closure that serializes a single node's subtree
/// to JSON `Data`.  Set by `ContentView`.  Used by `NodeRow` for copy-as-JSON
/// (P2-08) without a direct reference to `StructDocument`.
///
/// Parameters: `(nodeID: NodeID, pretty: Bool) -> Data?`
private struct SerializeNodeKey: EnvironmentKey {
    static let defaultValue: ((NodeID, Bool) -> Data?)? = nil
}

extension EnvironmentValues {
    /// Call this closure to serialize a node's subtree to JSON bytes.
    var serializeNode: ((NodeID, Bool) -> Data?)? {
        get { self[SerializeNodeKey.self] }
        set { self[SerializeNodeKey.self] = newValue }
    }
}

// parseScalarValue is defined in MachStructCore/Model/ScalarValue.swift
// and re-exported via `import MachStructCore` above.
