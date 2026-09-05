import AppKit
import SwiftUI

struct SettingsDiagnosticsSection: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updateController: UpdateController

    @State private var didCopy = false
    @State private var resetCopyTask: Task<Void, Never>?

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
        .onDisappear {
            resetCopyTask?.cancel()
            resetCopyTask = nil
            didCopy = false
        }
    }

    private func copyDiagnostics() {
        let report = PrivacySafeDiagnosticsReport.make(
            appState: appState,
            updateController: updateController
        )
        resetCopyTask?.cancel()
        NSPasteboard.general.clearContents()
        didCopy = NSPasteboard.general.setString(report, forType: .string)

        resetCopyTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            didCopy = false
            resetCopyTask = nil
        }
    }
}
