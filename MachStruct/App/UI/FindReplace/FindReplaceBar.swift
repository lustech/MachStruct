import SwiftUI
import MachStructCore

// MARK: - FindReplaceBar (v2.0 Data Workbench)

/// A find-&-replace bar for bulk edits across keys and values.
///
/// Owns the find/replace text and option toggles; `ContentView` performs the
/// match count and the undoable Replace All through `SearchEngine`.
struct FindReplaceBar: View {

    @Binding var find: String
    @Binding var replace: String
    @Binding var useRegex: Bool
    @Binding var caseSensitive: Bool
    @Binding var scope: SearchEngine.FindOptions.Scope

    /// Current match count for the find field (computed by `ContentView`).
    let matchCount: Int

    let onReplaceAll: () -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)

                TextField("Find", text: $find)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)

                Text(find.isEmpty ? "" : "\(matchCount) match\(matchCount == 1 ? "" : "es")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)

                optionToggles

                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close find & replace")
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)

                TextField("Replace", text: $replace)
                    .textFieldStyle(.roundedBorder)

                Button("Replace All", action: onReplaceAll)
                    .disabled(find.isEmpty || matchCount == 0)
                    .help("Replace every match in one undoable step")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onAppear { focused = true }
    }

    private var optionToggles: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $caseSensitive) { Text("Aa") }
                .toggleStyle(.button)
                .help("Case sensitive")

            Toggle(isOn: $useRegex) { Text(".*") }
                .toggleStyle(.button)
                .help("Regular expression")

            Picker("", selection: $scope) {
                Text("Keys").tag(SearchEngine.FindOptions.Scope.keys)
                Text("Values").tag(SearchEngine.FindOptions.Scope.values)
                Text("Both").tag(SearchEngine.FindOptions.Scope.both)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}
