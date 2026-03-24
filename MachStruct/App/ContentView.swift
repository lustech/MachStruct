import SwiftUI

// Placeholder window. Replaced by TreeView + StatusBar in P1-08 / P1-09.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "curlybraces")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
            Text("MachStruct")
                .font(.title2.weight(.semibold))
            Text("Drop a JSON file here to open it.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .frame(width: 960, height: 640)
}
