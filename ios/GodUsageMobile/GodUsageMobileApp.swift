import SwiftUI

@main
struct GodUsageMobileApp: App {
    @State private var teams = TeamsModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TeamsView(model: teams)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await teams.refresh() }
                    }
                }
                // A pairing QR code scanned with the Camera app opens godusage://pair.
                .onOpenURL { url in
                    guard url.scheme == "godusage", url.host == "pair" else { return }
                    Task { await teams.pair(with: url.absoluteString) }
                }
        }
    }
}
