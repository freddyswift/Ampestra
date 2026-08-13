import AppKit
import SwiftUI

/// Settings window shell for connection management, volume behavior, media-key
/// permissions, updates, and diagnostics.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var initialFocusResetToken = 0
    @AppStorage("settingsPage") private var selectedPage: SettingsPage = .simple

    private enum SettingsPage: String, CaseIterable, Identifiable {
        case simple = "Simple"
        case advanced = "Advanced"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeaderView()
            pagePicker

            switch selectedPage {
            case .simple:
                simplePage
            case .advanced:
                advancedPage
            }
        }
        .padding(16)
        .frame(width: MenuPanelLayout.width, alignment: .topLeading)
        .panelWindowBackground()
        .menuPanelSurface()
        .background(SettingsFocusSink(trigger: initialFocusResetToken))
        .onAppear {
            appState.refreshMediaKeyAccessStatus()
            initialFocusResetToken += 1
        }
    }

    private var pagePicker: some View {
        Picker("Settings page", selection: $selectedPage) {
            ForEach(SettingsPage.allCases) { page in
                Text(page.rawValue).tag(page)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
    }

    private var simplePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            SpeakerSettingsSection()
            VolumeStepSettingsSection()
            KeyboardVolumeSettingsSection()
            AppUpdateSettingsSection()
        }
        .transition(.identity)
    }

    private var advancedPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            AdvancedConnectionOptionsSection()
            SettingsDiagnosticsSection()
        }
        .transition(.identity)
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
