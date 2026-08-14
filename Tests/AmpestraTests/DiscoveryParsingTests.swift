import Darwin
import Network
import XCTest
@testable import KEFCore

final class DiscoveryParsingTests: XCTestCase {
    func testParsesRAOPServiceNames() {
        let parsed = KEFDiscovery.parseRAOPServiceName("AABBCCDDEEFF@KEF LSX II")
        XCTAssertEqual(parsed?.speakerName, "KEF LSX II")
        XCTAssertEqual(parsed?.macAddress, "AA:BB:CC:DD:EE:FF")
    }

    func testRejectsInvalidRAOPServiceNames() {
        XCTAssertNil(KEFDiscovery.parseRAOPServiceName("AABBCCDDEE@KEF LSX II"))
        XCTAssertNil(KEFDiscovery.parseRAOPServiceName("not-a-speaker"))
    }

    func testNormalizesHostnameAndServiceName() {
        XCTAssertEqual(KEFDiscovery.normalizedHostname("Speaker-Kitchen.local."), "speaker-kitchen.local")
        XCTAssertEqual(KEFDiscovery.normalizedServiceName("  KEF   LS50 Wireless II  "), "kef ls50 wireless ii")
    }

    func testRecognizesLocalNetworkPolicyDenial() {
        XCTAssertTrue(
            KEFDiscovery.isLocalNetworkPolicyDenied(.dns(Int32(kDNSServiceErr_PolicyDenied)))
        )
        XCTAssertFalse(
            KEFDiscovery.isLocalNetworkPolicyDenied(.posix(.ECONNREFUSED))
        )
    }
}
