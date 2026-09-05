import KEFCore
import SwiftUI

struct AdvancedConnectionOptionsSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var ipField = ""
    @State private var testResult: TestResult?
    @State private var manualHostTestTask: Task<Void, Never>?
    @State private var manualHostTestGeneration = 0
    @State private var testedHost: String?
    @FocusState private var isManualHostFocused: Bool

    private enum TestResult {
        case testing
        case failure(String)
    }

    var body: some View {
        Group {
            Section("Discovery") {
                LabeledContent("Automatic") {
                    autoDiscoveryToggle
                }

                discoveryActionRow
            }

            Section("Manual Connection") {
                LabeledContent("Host") {
                    manualIPEditor
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Use this if discovery misses your speaker.")
                        .font(.caption)
                        .foregroundStyle(PanelColors.secondaryText)

                    manualHostStatusRow
                }
            }
        }
        .onAppear {
            ipField = appState.manualIP
        }
        .onDisappear {
            cancelManualHostTest()
            testResult = nil
            testedHost = nil
        }
        .onChange(of: ipField) { _, _ in
            guard let testedHost, manualHostInput != testedHost else { return }
            cancelManualHostTest()
            testResult = nil
            self.testedHost = nil
        }
    }

    private var autoDiscoveryToggle: some View {
        Toggle("Automatic discovery", isOn: $appState.useAutoDiscovery)
            .labelsHidden()
            .toggleStyle(.switch)
            .onChange(of: appState.useAutoDiscovery) { _, _ in
                cancelManualHostTest()
                testResult = nil
                appState.startConnection()
            }
    }

    private var discoveryActionRow: some View {
        HStack(spacing: 8) {
            if appState.discovery.isSearching {
                ProgressView()
                    .controlSize(.mini)
            }

            Text(discoverySummary)
                .font(.caption)
                .foregroundStyle(PanelColors.secondaryText)

            Spacer(minLength: 8)

            Button {
                startDiscoveryFromSettings()
            } label: {
                Label("Scan Now", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Scan for speakers")
            .disabled(appState.discovery.isSearching || !appState.useAutoDiscovery)
        }
    }

    private var manualIPEditor: some View {
        HStack(spacing: 8) {
            TextField(
                "Manual host",
                text: $ipField,
                prompt: Text("192.168.1.40 or speaker.local")
            )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($isManualHostFocused)
                .onSubmit { applyIP() }

            Button(action: manualIPAction) {
                Text(manualIPActionTitle)
            }
            .controlSize(.small)
            .disabled(manualHostInput.isEmpty || isTestingHost || appState.isBusy)
        }
    }

    private var manualIPActionTitle: String {
        if isTestingHost { return "Testing…" }
        if appState.isReconnecting, appState.currentHost == manualHostInput { return "Connecting…" }
        return isManualIPCurrentConnection ? "Disconnect" : "Connect"
    }

    private var isTestingHost: Bool {
        if case .testing = testResult { return true }
        return false
    }

    private var isManualIPCurrentConnection: Bool {
        guard appState.isConnected, let currentHost = appState.currentHost else {
            return false
        }

        return ManualHostValidator.normalizedHost(manualHostInput) == currentHost
    }

    private func manualIPAction() {
        if isManualIPCurrentConnection {
            cancelManualHostTest()
            appState.disconnect()
            testResult = nil
            isManualHostFocused = false
        } else {
            applyIP()
        }
    }

    @ViewBuilder
    private var manualHostStatusRow: some View {
        if let result = testResult {
            switch result {
            case .testing:
                StatusRow(title: "Testing host", detail: manualHostStatusDetail, systemImage: "hourglass", tint: .secondary) {
                    ProgressView()
                        .controlSize(.small)
                }
            case .failure(let message):
                StatusRow(title: "Couldn’t connect", detail: message, systemImage: "xmark.circle.fill", tint: .red)
            }
        } else if isSavedManualHostConnected, manualHostInput == savedManualHost {
            StatusRow(title: "Connected", detail: savedManualHost, systemImage: "checkmark.circle.fill", tint: .green)
        } else if appState.isReconnecting, appState.currentHost == manualHostInput {
            StatusRow(title: "Connecting", detail: manualHostInput, systemImage: "hifispeaker", tint: .secondary) {
                ProgressView()
                    .controlSize(.small)
            }
        } else if !savedManualHost.isEmpty, manualHostInput == savedManualHost, let error = appState.connectionError {
            StatusRow(title: "Couldn’t connect", detail: error, systemImage: "xmark.circle.fill", tint: .red)
        } else if !manualHostInput.isEmpty, manualHostInput != savedManualHost {
            Text("Connect to test and save this host.")
                .font(.caption)
                .foregroundStyle(PanelColors.secondaryText)
        } else if !savedManualHost.isEmpty {
            Text("This host will be used on the next launch.")
                .font(.caption)
                .foregroundStyle(PanelColors.secondaryText)
        }
    }

    private var discoverySummary: String {
        if appState.discovery.isSearching {
            return "Scanning the local network…"
        }

        let count = appState.discovery.speakers.count
        if count == 1 {
            return "1 speaker found"
        }

        return "\(count) speakers found"
    }

    private var manualHostInput: String {
        ipField.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var savedManualHost: String {
        appState.manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSavedManualHostConnected: Bool {
        !savedManualHost.isEmpty && appState.isConnected && appState.currentHost == savedManualHost
    }

    private var manualHostStatusDetail: String? {
        manualHostInput.isEmpty ? nil : manualHostInput
    }

    private func startDiscoveryFromSettings() {
        appState.scanForSpeakers()
    }

    private func applyIP() {
        let host = ipField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !isTestingHost, !appState.isBusy else { return }
        cancelManualHostTest()
        testedHost = host

        guard let normalizedHost = ManualHostValidator.normalizedHost(host) else {
            testResult = .failure("Enter a private local IP address or .local host.")
            return
        }

        ipField = normalizedHost
        testedHost = normalizedHost

        testResult = .testing
        let api = KEFSpeakerAPI(host: normalizedHost)
        manualHostTestGeneration += 1
        let generation = manualHostTestGeneration

        manualHostTestTask = Task { @MainActor in
            let ok = await api.testConnection()
            guard !Task.isCancelled,
                  generation == manualHostTestGeneration,
                  ipField == normalizedHost else {
                return
            }
            manualHostTestTask = nil

            if ok {
                // Reachability is not a completed connection. Let AppState's
                // actual connection status drive the result shown below.
                testResult = nil
                appState.manualIP = normalizedHost
                appState.connect(to: normalizedHost)
            } else {
                testResult = .failure("Cannot reach speaker at \(normalizedHost)")
            }
        }
    }

    private func cancelManualHostTest() {
        manualHostTestGeneration += 1
        manualHostTestTask?.cancel()
        manualHostTestTask = nil
    }
}
