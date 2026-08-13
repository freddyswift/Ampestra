import AppKit
import SwiftUI

struct SettingsDiagnosticsSection: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updateController: UpdateController

    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diagnostic Report")
                    .font(.body)

                Text("No addresses or media details are included.")
                    .font(.caption)
                    .foregroundStyle(PanelColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                copyDiagnostics()
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .help("Copy diagnostics")
        }
    }

    private func copyDiagnostics() {
        let report = PrivacySafeDiagnosticsReport.make(
            appState: appState,
            updateController: updateController
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        didCopy = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }
}
