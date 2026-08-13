import XCTest
@testable import KEFCompanion

final class ManualHostValidatorTests: XCTestCase {
    func testAcceptsPrivateIPv4Addresses() {
        XCTAssertEqual(ManualHostValidator.normalizedHost(" 192.168.1.40 "), "192.168.1.40")
        XCTAssertEqual(ManualHostValidator.normalizedHost("10.0.0.2"), "10.0.0.2")
        XCTAssertEqual(ManualHostValidator.normalizedHost("172.16.0.10"), "172.16.0.10")
        XCTAssertEqual(ManualHostValidator.normalizedHost("169.254.1.1"), "169.254.1.1")
    }

    func testRejectsPublicOrMalformedHosts() {
        XCTAssertNil(ManualHostValidator.normalizedHost("8.8.8.8"))
        XCTAssertNil(ManualHostValidator.normalizedHost("https://speaker.local"))
        XCTAssertNil(ManualHostValidator.normalizedHost("speaker.local/path"))
        XCTAssertNil(ManualHostValidator.normalizedHost("speaker local"))
    }

    func testAcceptsLocalHostnames() {
        XCTAssertEqual(ManualHostValidator.normalizedHost("Speaker-Kitchen.local"), "speaker-kitchen.local")
        XCTAssertNil(ManualHostValidator.normalizedHost("-bad.local"))
        XCTAssertNil(ManualHostValidator.normalizedHost("bad-.local"))
    }

    func testDiscoveryHostsRejectLoopbackAndPublicDestinations() {
        XCTAssertEqual(ManualHostValidator.normalizedDiscoveryHost("192.168.1.40"), "192.168.1.40")
        XCTAssertEqual(ManualHostValidator.normalizedDiscoveryHost("Speaker-Kitchen.local"), "speaker-kitchen.local")
        XCTAssertNil(ManualHostValidator.normalizedDiscoveryHost("127.0.0.1"))
        XCTAssertNil(ManualHostValidator.normalizedDiscoveryHost("8.8.8.8"))
    }
}
