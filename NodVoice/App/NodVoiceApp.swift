import SwiftUI

@main
struct NodVoiceApp: App {
    @StateObject private var session = SessionController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .onOpenURL { session.handleOpenURL($0) }
                .onAppear { session.onAppear() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { session.onAppear() }
                }
        }
    }
}
