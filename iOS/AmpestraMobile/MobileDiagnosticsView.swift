import SwiftUI
import UIKit

struct MobileDiagnosticsView: View {
    let report: String
    @State private var copied = false

    var body: some View {
        List {
            Section {
                ShareLink(item: report) {
                    Label("Share diagnostic report", systemImage: "square.and.arrow.up")
                }
                Button(action: copyReport) {
                    Label(copied ? "Copied" : "Copy diagnostic report", systemImage: "doc.on.doc")
                }
            } footer: {
                Text("Includes app and iOS versions, connection status, and recent error categories from this session. Speaker names, network addresses, playback details, and error messages are excluded.")
            }
            Section("Report preview") {
                Text(report)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copyReport() {
        UIPasteboard.general.string = report
        copied = true
    }
}
