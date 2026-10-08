import Charts
import SwiftUI

/// The Teams tab: linking with a Mac by QR code, then your own usage from the server and your
/// teams' leaderboards.
struct TeamsView: View {
    var model: TeamsModel
    @State private var isScanning = false
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if model.isSignedIn {
                    signedIn
                } else {
                    signedOut
                }
            }
            .navigationTitle("Teams")
            .navigationDestination(for: TeamSummary.self) { team in
                TeamBoardView(model: model, team: team)
            }
            .refreshable { await model.refresh() }
            .toolbar {
                if model.isSignedIn {
                    Menu {
                        Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                }
            }
            .confirmationDialog("Sign out of GodUsage on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
            } message: {
                Text("You can link it again with a new code from your Mac.")
            }
            .sheet(isPresented: $isScanning) {
                ScanSheet { text in
                    isScanning = false
                    Task { await model.pair(with: text) }
                }
            }
        }
    }

    @ViewBuilder
    private var signedOut: some View {
        Section {
            ContentUnavailableView {
                Label("Link With Your Mac", systemImage: "qrcode.viewfinder")
            } description: {
                Text("On your Mac, open GodUsage Settings → Teams and choose Link iPhone or iPad. Then scan the code to see your usage and your teams here, with any iCloud account.")
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

    @ViewBuilder
    private var signedIn: some View {
        if let usage = model.myUsage {
            Section {
                HStack {
                    tile("Today", usage.today.map { UsageTotals(tokens: $0.tokens, costUSD: $0.costUSD) })
                    Divider()
                    tile("Last 30 Days", usage.total)
                }
                if usage.days.contains(where: { $0.tokens > 0 }) {
                    Chart(usage.days) { day in
                        BarMark(x: .value("Day", day.day), y: .value("Spend", day.costUSD))
                            .foregroundStyle(.tint)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 64)
                    .padding(.vertical, 4)
                }
                ForEach(usage.providers) { provider in
                    LabeledContent(TeamsFormat.providerName(provider.provider)) {
                        Text("\(TeamsFormat.cost(provider.costUSD)) · \(TeamsFormat.tokens(provider.tokens))")
                    }
                }
            } header: {
                Text("Your Usage")
            } footer: {
                Text(TeamsFormat.syncAge(usage.lastSyncAt) ?? "Your Macs share usage once you're in a team.")
            }
        } else if model.isLoading {
            Section { ProgressView().frame(maxWidth: .infinity) }
        }

        Section {
            if model.teams.isEmpty, !model.isLoading {
                Text("You're not in a team yet. Create or join one in GodUsage on your Mac.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.teams) { team in
                NavigationLink(value: team) {
                    LabeledContent(team.name) {
                        Text(team.memberCount == 1 ? "1 member" : "\(team.memberCount) members")
                    }
                }
            }
        } header: {
            Text("Your Teams")
        } footer: {
            if let name = model.session?.user.displayName {
                Text("Signed in as \(name).")
            }
        }
        .task { await model.refresh() }
    }

    private func tile(_ title: String, _ totals: UsageTotals?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(totals.map { TeamsFormat.cost($0.costUSD) } ?? "–").font(.title3.weight(.semibold)).monospacedDigit()
            Text(totals.map { "\(TeamsFormat.tokens($0.tokens)) tokens" } ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
