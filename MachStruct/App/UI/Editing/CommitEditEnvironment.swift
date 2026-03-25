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

// parseScalarValue is defined in MachStructCore/Model/ScalarValue.swift
// and re-exported via `import MachStructCore` above.
