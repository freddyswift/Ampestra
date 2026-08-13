import SwiftUI

struct AdvancedConnectionOptionsSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var ipField = ""
    @State private var testResult: TestResult?
    @State private var isManualHostEditorVisible = false
    @State private var manualHostTestTask: Task<Void, Never>?
    @State private var manualHostTestGeneration = 0
    @FocusState private var isManualHostFocused: Bool

    private enum TestResult {
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        SettingsSection(title: "Connection Options", systemImage: "network") {
            autoDiscoveryToggle
            manualIPEditor
            manualHostStatusRow
        }
        .onAppear {
            ipField = appState.manualIP
            isManualHostEditorVisible = !appState.manualIP.isEmpty
        }
        .onDisappear {
            cancelManualHostTest()
        }
    }

    private var autoDiscoveryToggle: some View {
        SettingsControlRow("Discovery") {
            HStack(spacing: 8) {
                Button {
                    startDiscoveryFromSettings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 18, height: 18)
                }
                .controlSize(.small)
                .panelFloatingButtonStyle()
                .help("Rescan")
                .disabled(appState.discovery.isSearching || !appState.useAutoDiscovery)

                Toggle("Find speakers automatically", isOn: $appState.useAutoDiscovery)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: appState.useAutoDiscovery) { _, _ in
                        cancelManualHostTest()
                        testResult = nil
                        appState.startConnection()
                    }
            }
        }
    }

    @ViewBuilder
    private var manualIPEditor: some View {
        if isManualHostEditorVisible {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Connect manually")
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Button(action: manualIPAction) {
                        Label(manualIPActionTitle, systemImage: manualIPActionIcon)
                    }
                    .controlSize(.small)
                    .disabled(ipField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                TextField("192.168.1.40 or speaker.local", text: $ipField)
                    .textFieldStyle(.roundedBorder)
                    .focused($isManualHostFocused)
                    .onSubmit { applyIP() }
            }
        } else {
            Button {
                isManualHostEditorVisible = true
                DispatchQueue.main.async {
                    isManualHostFocused = true
                }
            } label: {
                Label("Add Manual Host", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private var manualIPActionTitle: String {
        isManualIPCurrentConnection ? "Disconnect" : "Connect"
    }

    private var manualIPActionIcon: String {
        isManualIPCurrentConnection ? "xmark.circle" : "link"
    }

    private var isManualIPCurrentConnection: Bool {
        guard appState.isConnected, let currentHost = appState.currentHost else {
            return false
        }

        return ipField.trimmingCharacters(in: .whitespacesAndNewlines) == currentHost
    }

    private func manualIPAction() {
        if isManualIPCurrentConnection {
            cancelManualHostTest()
            appState.disconnect()
            appState.manualIP = ""
            ipField = ""
            testResult = nil
            isManualHostFocused = false
            isManualHostEditorVisible = false
        } else {
            applyIP()
        }
    }

    @ViewBuilder
    private var manualHostStatusRow: some View {
        if let result = testResult {
            switch result {
            case .testing:
                StatusRow(title: "Testing manual host", detail: manualHostStatusDetail, systemImage: "hourglass", tint: .secondary) {
                    ProgressView()
                        .controlSize(.small)
                }
            case .success(let name):
                StatusRow(title: "Manual host connected", detail: name, systemImage: "checkmark.circle.fill", tint: .green)
            case .failure(let message):
                StatusRow(title: "Manual host failed", detail: message, systemImage: "xmark.circle.fill", tint: .red)
            }
        } else if manualHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            StatusRow(title: "Manual host not set", detail: "Use this if discovery misses your speaker.", systemImage: "minus.circle", tint: .secondary)
        } else if manualHostInput != savedManualHost {
            StatusRow(title: "Manual host not saved", detail: "Press Connect to test and save it.", systemImage: "pencil.circle", tint: .orange)
        } else if isSavedManualHostConnected {
            StatusRow(title: "Manual host connected", detail: savedManualHost, systemImage: "checkmark.circle.fill", tint: .green)
        } else {
            StatusRow(title: "Manual host saved", detail: "Will connect to \(savedManualHost) on launch.", systemImage: "link.circle", tint: .secondary)
        }
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
        guard !host.isEmpty else { return }
        cancelManualHostTest()

        guard let normalizedHost = ManualHostValidator.normalizedHost(host) else {
            testResult = .failure("Enter a private local IP address or .local host.")
            return
        }

        ipField = normalizedHost

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

            if ok {
                let name = (try? await api.getSpeakerName()) ?? normalizedHost
                guard !Task.isCancelled,
                      generation == manualHostTestGeneration,
                      ipField == normalizedHost else {
                    return
                }
                testResult = .success(name)
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
