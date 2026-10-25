import SwiftUI

@main
struct BrailioApp: App {
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BRAILIO_UI_TEST_RESET"] == "1" {
            for key in ["tactileMode", "touchExplore", "messageDraft", "readerText", "notes", "findQuery", "destinationQuery", "routeProvider"] { UserDefaults.standard.removeObject(forKey: key) }
        }
        #endif
        BackendAccess.bootstrap(); DemoAccess.bootstrap()
    }
    var body: some Scene { WindowGroup { RootView() } }
}

struct RootView: View {
    @StateObject private var reader = HapticReader()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        HomeView()
        .tint(Theme.accent)
        .environmentObject(reader)
        .onChange(of: scenePhase) { _, phase in if phase != .active { reader.stop() } }
    }
}
