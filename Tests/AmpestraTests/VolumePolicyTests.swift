import XCTest
@testable import Ampestra

final class VolumePolicyTests: XCTestCase {
    func testClampsStepSize() {
        XCTAssertEqual(VolumePolicy.clampedStepSize(-5), 1)
        XCTAssertEqual(VolumePolicy.clampedStepSize(5), 5)
        XCTAssertEqual(VolumePolicy.clampedStepSize(50), 25)
    }

    func testNormalizesAnyValueMode() {
        let policy = VolumePolicy(usesFixedSteps: false, stepSize: 5)
        XCTAssertEqual(policy.normalizedVolume(-1), 0)
        XCTAssertEqual(policy.normalizedVolume(37), 37)
        XCTAssertEqual(policy.normalizedVolume(101), 100)
    }

    func testNormalizesFixedStepMode() {
        let policy = VolumePolicy(usesFixedSteps: true, stepSize: 5)
        XCTAssertEqual(policy.normalizedVolume(37), 35)
        XCTAssertEqual(policy.normalizedVolume(38), 40)
        XCTAssertEqual(policy.normalizedVolume(99), 100)
    }

    func testNextVolumeUsesConfiguredSteps() {
        let policy = VolumePolicy(usesFixedSteps: true, stepSize: 5)
        XCTAssertEqual(policy.nextVolume(from: 37, direction: 1), 40)
        XCTAssertEqual(policy.nextVolume(from: 40, direction: -1), 35)
        XCTAssertEqual(policy.nextVolume(from: 0, direction: -1), 0)
        XCTAssertEqual(policy.nextVolume(from: 100, direction: 1), 100)
    }

    func testMuteToggleStoresCurrentVolumeAndMutes() {
        let result = VolumePolicy.muteToggle(from: 37, restoreVolume: nil)

        XCTAssertEqual(result.targetVolume, 0)
        XCTAssertEqual(result.restoreVolume, 37)
    }

    func testMuteToggleRestoresExactPreviousVolume() {
        let result = VolumePolicy.muteToggle(from: 0, restoreVolume: 37)

        XCTAssertEqual(result.targetVolume, 37)
        XCTAssertNil(result.restoreVolume)
    }

    func testMuteToggleWithoutRestoreStaysMuted() {
        let result = VolumePolicy.muteToggle(from: 0, restoreVolume: nil)

        XCTAssertEqual(result.targetVolume, 0)
        XCTAssertNil(result.restoreVolume)
    }

    func testMuteToggleClampsRestoreVolume() {
        let result = VolumePolicy.muteToggle(from: 0, restoreVolume: 150)

        XCTAssertEqual(result.targetVolume, 100)
        XCTAssertNil(result.restoreVolume)
    }
}
