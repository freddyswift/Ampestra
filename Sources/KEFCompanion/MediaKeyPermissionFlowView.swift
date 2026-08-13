import AppKit
import SwiftUI

/// Contextual setup for the optional hardware-volume-key feature. Each stage
/// presents one next action and rechecks access when the app becomes active.
struct MediaKeyPermissionFlowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            StatusRow(
                title: currentStep.title,
                detail: currentStep.detail,
                systemImage: currentStep.systemImage,
                tint: currentStep.tint
            )

            if let action = currentStep.action {
                Button(action: action.perform) {
                    Label(action.title, systemImage: action.systemImage)
                }
                .controlSize(.small)
            }

            if appState.needsRestartForMediaKeyAccess {
                StatusRow(
                    title: "Listener needs a restart",
                    detail: "Both permissions are on, but macOS did not activate the volume-key listener.",
                    systemImage: "restart.circle",
                    tint: .orange
                ) {
                    Button("Restart") {
                        appState.restartApp()
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            appState.refreshMediaKeyAccessStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshMediaKeyAccessStatus()
        }
    }

    private var currentStep: MediaKeyPermissionStep {
        switch appState.mediaKeyAccessState {
        case .inputMonitoringNeeded:
            return MediaKeyPermissionStep(
                title: "Use hardware volume keys",
                detail: "KEF Companion needs Input Monitoring to detect the volume media keys. It does not record ordinary typing.",
                systemImage: "keyboard",
                tint: .blue,
                action: .init(
                    title: "Continue",
                    systemImage: "arrow.right",
                    perform: appState.requestMediaKeyAccess
                )
            )
        case .inputMonitoringDenied:
            return MediaKeyPermissionStep(
                title: "Input Monitoring is off",
                detail: "Turn on KEF Companion in Privacy & Security, then return here.",
                systemImage: "hand.raised.circle",
                tint: .orange,
                action: .init(
                    title: "Open System Settings",
                    systemImage: "gearshape",
                    perform: appState.openInputMonitoringSettings
                )
            )
        case .accessibilityNeeded:
            return MediaKeyPermissionStep(
                title: "Prevent double volume changes",
                detail: "Accessibility lets KEF Companion intercept only the volume keys it routes to your speaker, so Mac volume does not change too.",
                systemImage: "accessibility",
                tint: .blue,
                action: .init(
                    title: "Continue",
                    systemImage: "arrow.right",
                    perform: appState.requestMediaKeyAccess
                )
            )
        case .accessibilityDenied:
            return MediaKeyPermissionStep(
                title: "Accessibility is off",
                detail: "Turn on KEF Companion in Privacy & Security, then return here.",
                systemImage: "accessibility",
                tint: .orange,
                action: .init(
                    title: "Open System Settings",
                    systemImage: "gearshape",
                    perform: appState.openAccessibilitySettings
                )
            )
        case .failedToActivate:
            return MediaKeyPermissionStep(
                title: "Volume-key listener did not start",
                detail: appState.mediaKeyAccessMessage,
                systemImage: "exclamationmark.circle",
                tint: .orange,
                action: nil
            )
        case .working:
            return MediaKeyPermissionStep(
                title: "Hardware volume keys are ready",
                detail: "KEF Companion only consumes a volume key when it is routed to your speaker.",
                systemImage: "checkmark.circle.fill",
                tint: .green,
                action: nil
            )
        case .unknown:
            return MediaKeyPermissionStep(
                title: "Hardware volume keys are off",
                detail: "Choose Auto or KEF above to enable this optional feature.",
                systemImage: "keyboard",
                tint: .secondary,
                action: nil
            )
        }
    }
}

private struct MediaKeyPermissionStep {
    struct Action {
        let title: String
        let systemImage: String
        let perform: () -> Void
    }

    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let action: Action?
}
