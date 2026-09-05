import XCTest
@testable import Ampestra
@testable import KEFCore

@MainActor
final class AppStateSecurityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetConnectionDefaults()
    }

    override func tearDown() {
        resetConnectionDefaults()
        super.tearDown()
    }

    func testAutoConnectionCandidatesRequirePreviouslyTrustedHosts() {
        let appState = AppState(startImmediately: false)
        let discoveredSpeakers = [
            DiscoveredSpeaker(id: "fake", name: "KEF LSX II", host: "192.168.1.77", macAddress: nil)
        ]

        XCTAssertEqual(appState.trustedAutoConnectionCandidates(from: discoveredSpeakers), [])
    }

    func testAutoConnectionCandidatesKeepTrustedLocalHostsOnly() {
        UserDefaults.standard.set("192.168.1.50\nspeaker-kitchen.local\n8.8.8.8", forKey: "trustedSpeakerHosts")
        let appState = AppState(startImmediately: false)
        let discoveredSpeakers = [
            DiscoveredSpeaker(id: "trusted-ip", name: "KEF LSX II", host: "192.168.1.50", macAddress: nil),
            DiscoveredSpeaker(id: "trusted-local", name: "KEF LS50", host: "Speaker-Kitchen.local", macAddress: nil),
            DiscoveredSpeaker(id: "public", name: "KEF LS60", host: "8.8.8.8", macAddress: nil),
            DiscoveredSpeaker(id: "untrusted", name: "KEF LSX II", host: "192.168.1.77", macAddress: nil),
        ]

        XCTAssertEqual(
            appState.trustedAutoConnectionCandidates(from: discoveredSpeakers),
            ["192.168.1.50", "speaker-kitchen.local"]
        )
    }

    private func resetConnectionDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "manualIP")
        defaults.removeObject(forKey: "lastConnectedHost")
        defaults.removeObject(forKey: "trustedSpeakerHosts")
        defaults.removeObject(forKey: "useAutoDiscovery")
    }

    func testWakeAddressBelongsToSelectedSpeakerOnly() {
        let appState = AppState(startImmediately: false)
        appState.currentHost = "selected.local"
        appState.discovery.speakers = [
            DiscoveredSpeaker(id: "other", name: "Other", host: "other.local", macAddress: "AA:BB:CC:DD:EE:FF")
        ]
        XCTAssertNil(appState.speakerMAC)

        appState.discovery.speakers.append(
            DiscoveredSpeaker(id: "selected", name: "Selected", host: "selected.local", macAddress: "11:22:33:44:55:66")
        )
        XCTAssertEqual(appState.speakerMAC, "11:22:33:44:55:66")
    }
}
