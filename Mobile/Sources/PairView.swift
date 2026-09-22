import SwiftUI
import VisionKit

/// First launch: scan the QR code shown on the Mac (cMessage > Connect iPhone or iPad).
struct PairView: View {
    @EnvironmentObject var client: RemoteClient
    @State private var scanning = false
    @State private var pasted = ""
    @State private var failed = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "message.fill").font(.system(size: 64))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.59, blue: 0.35), Color(red: 0.91, green: 0.28, blue: 0.24)], startPoint: .top, endPoint: .bottom))
            Text("cChat").font(.largeTitle.bold())
            Text("Link to your Mac. On the Mac, open cChat and choose Connect iPhone or iPad, then scan the code.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
            if DataScannerViewController.isSupported {
                Button { scanning = true } label: {
                    Label("Scan Code", systemImage: "qrcode.viewfinder").frame(maxWidth: 280).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
            VStack(spacing: 8) {
                TextField("Or paste the link from your Mac", text: $pasted)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Link") { tryLink(pasted) }.disabled(pasted.isEmpty)
            }
            .frame(maxWidth: 360).padding(.horizontal)
            if failed { Text("That code didn't work. Try again.").foregroundStyle(.red).font(.callout) }
            Spacer()
        }
        .sheet(isPresented: $scanning) {
            QRScanner { code in scanning = false; tryLink(code) }.ignoresSafeArea()
        }
    }

    private func tryLink(_ s: String) {
        failed = !(URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)).map(client.pair(with:)) ?? false)
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        var done = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ s: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let b) in items {
                if let v = b.payloadStringValue, v.hasPrefix("cmessage://") { done = true; s.stopScanning(); found(v); return }
            }
        }
    }
}
