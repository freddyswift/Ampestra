import XCTest
@testable import KEFCore

final class WakeOnLANTests: XCTestCase {
    func testBuildsMagicPacket() {
        let packet = makeWakeOnLANMagicPacket(macAddress: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(packet?.count, 102)
        XCTAssertEqual(Array(packet?.prefix(6) ?? []), Array(repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(packet?[6..<12] ?? []), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        XCTAssertEqual(Array(packet?[96..<102] ?? []), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    func testRejectsInvalidMacAddress() {
        XCTAssertNil(makeWakeOnLANMagicPacket(macAddress: "not-a-mac"))
    }
}
