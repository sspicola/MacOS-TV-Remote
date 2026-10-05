import XCTest
@testable import ItsytvCore

final class AppleTVManagerLifecycleTests: XCTestCase {
    func testStopScanningClearsPreviouslyDiscoveredSnapshot() {
        let manager = AppleTVManager(enableMediaRemote: false)
        manager.discoveredDevices = [AppleTVDevice(
            id: "test", name: "test", host: "test.local", port: 49152, modelName: nil
        )]
        manager.isScanning = true

        manager.stopScanning()

        XCTAssertFalse(manager.isScanning)
        XCTAssertTrue(manager.discoveredDevices.isEmpty)
    }

    func testPINWithoutCurrentChallengeDoesNotAdvanceLifecycle() {
        let manager = AppleTVManager(enableMediaRemote: false)
        manager.submitPIN("1234")
        XCTAssertEqual(manager.connectionStatus, .disconnected)
        XCTAssertNil(manager.connectedDeviceID)
    }

    func testDisconnectClearsUserVisibleSessionState() {
        let manager = AppleTVManager(enableMediaRemote: false)
        manager.connectionStatus = .connected
        manager.connectedDeviceName = "test"
        manager.keyboardFocused = true
        manager.osVersion = "test"

        manager.disconnect()

        XCTAssertEqual(manager.connectionStatus, .disconnected)
        XCTAssertNil(manager.connectedDeviceName)
        XCTAssertNil(manager.connectedDeviceID)
        XCTAssertNil(manager.osVersion)
        XCTAssertFalse(manager.keyboardFocused)
    }
}
