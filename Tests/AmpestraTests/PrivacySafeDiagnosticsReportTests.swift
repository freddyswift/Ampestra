import XCTest
@testable import Ampestra
@testable import KEFCore

@MainActor
final class PrivacySafeDiagnosticsReportTests: XCTestCase {
    func testReportDoesNotIncludeRawNetworkOrMediaDetails() {
        let appState = AppState(startImmediately: false)
        let originalManualIP = appState.manualIP
        defer { appState.manualIP = originalManualIP }

        appState.manualIP = "192.168.1.40"
        appState.currentHost = "192.168.1.41"
        appState.connectionError = "Cannot reach 192.168.1.41"
        appState.status = .unknown("Private status from 192.168.1.41")
        appState.speakerName = "Kitchen LSX"
        appState.discovery.speakers = [
            DiscoveredSpeaker(
                id: "192.168.1.42",
                name: "Living Room LS60",
                host: "192.168.1.42",
                macAddress: "AA:BB:CC:DD:EE:FF"
            )
        ]
        appState.nowPlaying = NowPlayingInfo(title: "Private Song", artist: "Private Artist", album: "Private Album")

        let report = PrivacySafeDiagnosticsReport.make(
            appState: appState,
            updateController: UpdateController()
        )

        XCTAssertFalse(report.contains("192.168.1.40"))
        XCTAssertFalse(report.contains("192.168.1.41"))
        XCTAssertFalse(report.contains("192.168.1.42"))
        XCTAssertFalse(report.contains("Kitchen LSX"))
        XCTAssertFalse(report.contains("Living Room LS60"))
        XCTAssertFalse(report.contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse(report.contains("Cannot reach"))
        XCTAssertFalse(report.contains("Private Song"))
        XCTAssertFalse(report.contains("Private Artist"))
        XCTAssertFalse(report.contains("Private Album"))
        XCTAssertFalse(report.contains("Private status"))
        XCTAssertTrue(report.contains("Power status: unknown"))

        XCTAssertTrue(report.contains("Manual host configured: true"))
        XCTAssertTrue(report.contains("Current host present: true"))
        XCTAssertTrue(report.contains("Discovered speaker count: 1"))
        XCTAssertTrue(report.contains("Connection error present: true"))
    }
}
