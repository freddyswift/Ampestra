import AppKit
import SwiftUI

struct AppUpdateSettingsSection: View {
    @EnvironmentObject private var updateController: UpdateController

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Ampestra")
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text("\(appVersionSummary) · \(updateStatusDetail)")
                    .font(.caption)
                    .foregroundStyle(PanelColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if updateController.configurationState == .ready {
                updateCheckButton
            }
        }
    }

    private var updateCheckButton: some View {
        Button {
            updateController.checkForUpdates()
        } label: {
            Text("Check for Updates")
        }
        .controlSize(.small)
        .disabled(!updateController.canCheckForUpdates)
        .help("Check for updates")
    }

    private var appVersionSummary: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(shortVersion) (\(build))"
    }

    private var updateStatusDetail: String {
        switch updateController.configurationState {
        case .ready:
            return "Updates are checked automatically."
        case .localBuild:
            return "Built from source; automatic updates are unavailable."
        }
    }
}
