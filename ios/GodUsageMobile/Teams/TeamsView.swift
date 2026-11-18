import SwiftUI

/// The app's root: linking with a Mac by QR code while signed out, then two tabs, Team (selected on
/// launch) and You.
struct TeamsView: View {
    enum Tab: String { case team, you }

    var model: TeamsModel
    @State private var tab: Tab = Self.initialTab
    @State private var isScanning = false

    var body: some View {
        if model.isSignedIn {
            TabView(selection: $tab) {
                TeamTabView(model: model)
                    .tabItem { Label("Team", systemImage: "person.3") }
                    .tag(Tab.team)
                YouTabView(model: model)
                    .tabItem { Label("You", systemImage: "person.crop.circle") }
                    .tag(Tab.you)
            }
            .task { await model.refresh() }
        } else {
            signedOut
        }
    }

    /// Team, except in DEBUG screenshots launched with `-startTab you`.
    private static var initialTab: Tab {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "startTab"), let tab = Tab(rawValue: name) { return tab }
        #endif
        return .team
    }

    private var signedOut: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    ContentUnavailableView {
                        Label("Link With Your Mac", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text("On your Mac, open GodUsage Settings → Teams and choose Link iPhone or iPad. Then scan the code to see your usage and your teams here.")
                    } actions: {
                        Button {
                            model.errorMessage = nil
                            isScanning = true
                        } label: {
                            if model.isPairing {
                                ProgressView()
                            } else {
                                Text("Scan Code")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isPairing)
                    }
                }
            }
            .navigationTitle("Teams")
            .sheet(isPresented: $isScanning) {
                ScanSheet { text in
                    isScanning = false
                    Task { await model.pair(with: text) }
                }
            }
        }
    }
}

private struct ScanSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if QRScannerView.isAvailable {
                    QRScannerView(onScan: onScan).ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Camera Unavailable",
                        systemImage: "camera",
                        description: Text("Allow GodUsage to use the camera in Settings, or scan the code with the Camera app.")
                    )
                }
            }
            .navigationTitle("Scan Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
