import SwiftUI

@main
@MainActor
struct MacFileInventoryApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Atlas") {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 760)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Scan") {
                Button("Scan") { appState.startScan() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Pause") { appState.pauseScan() }
                Button("Resume") { appState.resumeScan() }
                Button("Stop") { appState.stopScan() }
            }
        }
    }
}
