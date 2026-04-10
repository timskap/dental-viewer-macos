import SwiftUI

struct DentalViewerApp: App {
    @StateObject private var store = VolumeStore()

    var body: some Scene {
        WindowGroup("Dental Viewer") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1100, minHeight: 760)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open DICOM Folder…") { store.openFolder() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
