import SwiftUI
import CoreImage.CIFilterBuiltins

/// Shows the QR code the iPhone/iPad app scans once to link to this Mac.
struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var server = RemoteServer.shared
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Connect iPhone or iPad").font(.title2.bold())
            if let p = server.pairing {
                if let img = qr(p.url.absoluteString) {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 240, height: 240)
                        .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                Text("Open cChat on your iPhone or iPad and scan this. Both need to be on the same Wi-Fi as this Mac.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(width: 360)
                HStack(spacing: 6) {
                    Circle().fill(server.running ? .green : .orange).frame(width: 8, height: 8)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Text("Treat this code like a password. Anyone who scans it can text your agents.")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center).frame(width: 360)
                HStack {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(p.url.absoluteString, forType: .string)
                    }
                    Button("New Code (disconnects devices)") { confirmReset = true }
                    Button("Turn Off", role: .destructive) { server.unpair() }
                }
            } else {
                Text("Your Mac stays in charge; the agents keep running here. Your iPhone and iPad become remote screens for the same chats.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(width: 360)
                Button("Set Up") { server.newPairing() }.buttonStyle(.borderedProminent)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .confirmationDialog("Make a new code?", isPresented: $confirmReset) {
            Button("New Code", role: .destructive) { server.newPairing() }
        } message: { Text("Any iPhone or iPad already linked will need to scan again.") }
    }

    private var status: String {
        guard server.running else { return "Starting…" }
        if let when = server.lastSeen { return "Connected · last heard \(when.formatted(.relative(presentation: .named)))" }
        return "Waiting for a device"
    }

    private func qr(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
    }
}
