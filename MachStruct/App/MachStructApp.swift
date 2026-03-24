import SwiftUI

// MARK: - MachStructApp

@main
struct MachStructApp: App {
    var body: some Scene {
        // DocumentGroup wires up:
        //   • File > Open  (Cmd+O)
        //   • File > Open Recent
        //   • Drag-and-drop onto the Dock icon or open window
        //   • One window per open document
        DocumentGroup(viewing: StructDocument.self) { file in
            ContentView(document: file.document)
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}
