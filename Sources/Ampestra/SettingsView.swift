import AppKit
import SwiftUI

/// Settings window shell for connection management, volume behavior, media-key
/// permissions, updates, and diagnostics.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var initialFocusResetToken = 0
    @AppStorage("settingsPage") private var selectedPageRawValue = SettingsPage.general.rawValue

    private enum SettingsPage: String {
        case general = "Simple"
        case connection = "Advanced"
    }

    var body: some View {
        TabView(selection: selectedPage) {
            generalPage
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsPage.general)

            connectionPage
                .tabItem {
                    Label("Connection", systemImage: "network")
                }
                .tag(SettingsPage.connection)
        }
        .frame(width: SettingsMetrics.windowWidth, height: settingsPageHeight)
        .background(SettingsFocusSink(trigger: initialFocusResetToken))
        .onAppear {
            appState.refreshMediaKeyAccessStatus()
            initialFocusResetToken += 1
        }
    }

    private var selectedPage: Binding<SettingsPage> {
        Binding(
            get: { SettingsPage(rawValue: selectedPageRawValue) ?? .general },
            set: { selectedPageRawValue = $0.rawValue }
        )
    }

    private var generalPage: some View {
        Form {
            Section {
                SpeakerSettingsSection()
            } header: {
                settingsSectionHeader("Speaker") {
                    speakerDiscoveryAction
                }
            }

            Section {
                VolumeStepSettingsRows()
                KeyboardVolumeSettingsRows()
            } header: {
                settingsSectionHeader("Volume Controls") {
                    if !appState.usesDefaultControlPreferences {
                        Button {
                            appState.resetControlPreferences()
                        } label: {
                            Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Restore the default volume controls")
                    }
                }
            }

            Section("Software Update") {
                AppUpdateSettingsSection()
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.automatic)
    }

    private var speakerDiscoveryAction: some View {
        HStack(spacing: 8) {
            if appState.discovery.isSearching {
                ProgressView()
                    .controlSize(.mini)
            }

            Button {
                appState.scanForSpeakers()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(appState.discovery.isSearching)
            .help("Scan for speakers")
        }
    }

    private var connectionPage: some View {
        Form {
            AdvancedConnectionOptionsSection()

            Section("Diagnostics") {
                SettingsDiagnosticsSection()
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.automatic)
    }

    private func settingsSectionHeader<Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)

            Spacer(minLength: 8)
            accessory()
        }
        .frame(maxWidth: .infinity)
    }

    private var settingsPageHeight: CGFloat {
        switch selectedPage.wrappedValue {
        case .general:
            return SettingsMetrics.generalPageHeight
        case .connection:
            return SettingsMetrics.connectionPageHeight
        }
    }
}

private struct SettingsFocusSink: NSViewRepresentable {
    let trigger: Int

    func makeNSView(context: Context) -> FocusSinkView {
        FocusSinkView()
    }

    func updateNSView(_ nsView: FocusSinkView, context: Context) {
        nsView.activateOnce(for: trigger)
    }

    static func dismantleNSView(_ nsView: FocusSinkView, coordinator: Void) {
        nsView.removeMouseDownMonitor()
    }

    final class FocusSinkView: NSView {
        private var activatedTrigger: Int?
        private var pendingTrigger: Int?
        private var mouseDownMonitor: Any?

        override var acceptsFirstResponder: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            installMouseDownMonitorIfNeeded()
            activatePendingTrigger()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeMouseDownMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func activateOnce(for trigger: Int) {
            guard activatedTrigger != trigger else { return }
            pendingTrigger = trigger
            activatePendingTrigger()
        }

        private func activatePendingTrigger() {
            guard let pendingTrigger, activatedTrigger != pendingTrigger, let window else {
                return
            }

            activatedTrigger = pendingTrigger
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                window.initialFirstResponder = self
                window.makeFirstResponder(self)
            }
        }

        private func installMouseDownMonitorIfNeeded() {
            guard mouseDownMonitor == nil else { return }

            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.dismissTextFocusIfNeeded(for: event)
                return event
            }
        }

        func removeMouseDownMonitor() {
            guard let mouseDownMonitor else { return }
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }

        private func dismissTextFocusIfNeeded(for event: NSEvent) {
            guard let window, event.window === window, isFirstResponderTextInput(in: window) else {
                return
            }

            guard let contentView = window.contentView else { return }
            let location = contentView.convert(event.locationInWindow, from: nil)
            let hitView = contentView.hitTest(location)
            guard !isTextInputTarget(hitView) else { return }

            window.makeFirstResponder(self)
        }

        private func isFirstResponderTextInput(in window: NSWindow) -> Bool {
            if window.firstResponder is NSTextView {
                return true
            }

            guard let firstResponderView = window.firstResponder as? NSView else {
                return false
            }

            return isTextInputTarget(firstResponderView)
        }

        private func isTextInputTarget(_ view: NSView?) -> Bool {
            var candidate = view
            while let current = candidate {
                if current is NSTextField || current is NSTextView {
                    return true
                }
                candidate = current.superview
            }

            return false
        }
    }
}
