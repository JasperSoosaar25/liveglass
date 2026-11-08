import SwiftUI

@main
struct LiveGlassApp: App {
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(app)
        }
        .onChange(of: scenePhase) { _, phase in
            app.handleScenePhase(phase)
        }
    }
}
