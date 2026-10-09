import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The Teams pane's iPhone and iPad section: the devices linked by QR pairing, unlinking them, and
/// the sheet with the QR code that links a new one.
struct TeamsLinkedDevicesSection: View {
    @Environment(AppContainer.self) private var container
    @State private var isShowingCode = false
    @State private var confirmingUnlink: LinkedDevice?

    var body: some View {
        let pairing = container.devicePairing
        SettingsSection("iPhone and iPad") {
            ForEach(pairing.linkedDevices) { device in
                SettingsRow(device.name) {
                    Button("Unlink…") { confirmingUnlink = device }
                        .disabled(pairing.isWorking)
                }
                Divider()
            }
            HStack {
                Button("Link iPhone or iPad…") {
                    isShowingCode = true
                    Task { await pairing.showCode() }
                }
                .disabled(pairing.isWorking)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if let message = pairing.errorMessage, !isShowingCode {
                SettingsInlineNotice(message)
            }
            SettingsCaption("Scan a code with the GodUsage app to see your usage and your teams on the go. A linked device stays signed in until you unlink it.")
        }
        .task { await pairing.loadDevices() }
        .sheet(isPresented: $isShowingCode, onDismiss: { pairing.hideCode() }) {
            PairingCodeSheet(pairing: pairing) { isShowingCode = false }
        }
        .alert(
            "Unlink \(confirmingUnlink?.name ?? "")?",
            isPresented: Binding(get: { confirmingUnlink != nil }, set: { if !$0 { confirmingUnlink = nil } }),
            presenting: confirmingUnlink
        ) { device in
            Button("Unlink", role: .destructive) { Task { await pairing.unlink(device) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's signed out of GodUsage and needs a new code to link again.")
        }
    }
}

private struct PairingCodeSheet: View {
    let pairing: DevicePairingStore
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Link iPhone or iPad").font(.headline)
            content
                .frame(width: 220, height: 220)
            footer
                .frame(maxWidth: 280)
                .multilineTextAlignment(.center)
            HStack {
                if pairing.activeCode == nil, pairing.justLinked == nil, !pairing.isWorking {
                    Button("New Code") { Task { await pairing.showCode() } }
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .task(id: pairing.activeCode) { await pairing.watchForNewDevice() }
    }

    @ViewBuilder
    private var content: some View {
        if let device = pairing.justLinked {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .accessibilityLabel("Linked \(device.name)")
        } else if let code = pairing.activeCode, let image = QRCodeImage.make(code.url.absoluteString) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("QR code to link a device")
        } else if pairing.isWorking {
            ProgressView()
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let device = pairing.justLinked {
            Text("\(device.name) is linked.")
        } else if let message = pairing.errorMessage {
            Text(message).foregroundStyle(Theme.notice)
        } else if let code = pairing.activeCode {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(code.expiresAt.timeIntervalSince(context.date).rounded(.up)))
                if remaining > 0 {
                    Text("Open GodUsage on your iPhone or iPad and scan this code. It works once and expires in \(remaining / 60):\(String(format: "%02d", remaining % 60)).")
                } else {
                    Text("This code expired.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Text("Get a new code to link a device.").foregroundStyle(.secondary)
        }
    }
}

/// QR codes drawn by Core Image, one module per pixel; the view scales them up without smoothing.
enum QRCodeImage {
    static func make(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else {
            AppLog.error(.teams, "couldn't draw the pairing QR code")
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
