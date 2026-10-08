import SwiftUI

@main
struct GodUsageMobileApp: App {
    @State private var model = UsageCloudModel()
    @State private var teams = TeamsModel()
    @State private var tab = Tab.usage
    @Environment(\.scenePhase) private var scenePhase

    enum Tab { case usage, teams }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                DashboardView(model: model)
                    .tabItem { Label("Usage", systemImage: "chart.bar") }
                    .tag(Tab.usage)
                TeamsView(model: teams)
                    .tabItem { Label("Teams", systemImage: "person.3") }
                    .tag(Tab.teams)
            }
            .task { await model.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await model.refresh()
                        await teams.refresh()
                    }
                }
            }
            // A pairing QR code scanned with the Camera app opens godusage://pair.
            .onOpenURL { url in
                guard url.scheme == "godusage", url.host == "pair" else { return }
                tab = .teams
                Task { await teams.pair(with: url.absoluteString) }
            }
        }
    }
}
