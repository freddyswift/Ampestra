import Darwin
import Network
import XCTest
@testable import KEFCore

final class DiscoveryParsingTests: XCTestCase {
    @MainActor
    func testDiscoveryFloodLimitsConcurrentAndTotalResolutions() async {
        let completed = expectation(description: "Bounded services resolved")
        completed.expectedFulfillmentCount = KEFDiscovery.maximumServices
        let probe = ResolutionProbe()
        let discovery = KEFDiscovery { name, _, _, _ in
            probe.begin()
            Thread.sleep(forTimeInterval: 0.01)
            probe.end()
            completed.fulfill()
            return name + ".local"
        }
        for index in 0..<1000 {
            discovery.scheduleServiceResolution(name: "speaker-\(index)", type: "_http._tcp", domain: "local", generation: 0)
        }
        await fulfillment(of: [completed], timeout: 4)
        discovery.stopDiscovery()
        XCTAssertEqual(probe.total, KEFDiscovery.maximumServices)
        XCTAssertLessThanOrEqual(probe.maximum, 4)
    }

    @MainActor
    func testStoppingDiscoveryCancelsActiveAndQueuedResolutions() async {
        let started = expectation(description: "Four active resolutions")
        started.expectedFulfillmentCount = 4
        let stopped = expectation(description: "Active resolutions cancelled")
        stopped.expectedFulfillmentCount = 4
        let discovery = KEFDiscovery { _, _, _, cancelled in
            started.fulfill()
            while !cancelled() { Thread.sleep(forTimeInterval: 0.01) }
            stopped.fulfill()
            return "discarded.local"
        }
        for index in 0..<64 {
            discovery.scheduleServiceResolution(name: "speaker-\(index)", type: "_http._tcp", domain: "local", generation: 0)
        }
        await fulfillment(of: [started], timeout: 2)
        discovery.stopDiscovery()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(discovery.speakers.isEmpty)
    }

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

private final class ResolutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var storedTotal = 0
    private var storedMaximum = 0
    var total: Int { lock.withLock { storedTotal } }
    var maximum: Int { lock.withLock { storedMaximum } }
    func begin() {
        lock.withLock {
            active += 1
            storedTotal += 1
            storedMaximum = max(storedMaximum, active)
        }
    }
    func end() { lock.withLock { active -= 1 } }
}
