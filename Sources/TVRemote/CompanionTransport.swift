import Foundation
import ItsytvCore
import Observation
import RemoteKit

/// Keeps discovery running while each connection attempt uses its own session.
@MainActor
final class CompanionTransport: RemoteTransport {
    var onDevicesChanged: (([RemoteDevice]) -> Void)?
    var onPhaseChanged: ((RemotePhase) -> Void)?
    private let scanner = AppleTVManager(enableMediaRemote: false)
    private var session: AppleTVManager?
    private var generation = 0
    private var scanGeneration = 0
    private var scanning = false

    func startScanning() {
        guard !scanning else { return }
        scanning = true
        scanGeneration += 1
        observeDevices(token: scanGeneration)
        scanner.startScanning()
    }

    func refreshScanning() {
        // Stop/start avoids the upstream refresh's unrelated port-knocking behavior.
        stopScanning()
        startScanning()
    }

    func stopScanning() {
        scanning = false
        scanGeneration += 1
        scanner.stopScanning()
    }

    func connect(to device: RemoteDevice) {
        disconnect()
        let manager = AppleTVManager(enableMediaRemote: false)
        session = manager
        manager.connect(to: AppleTVDevice(id: device.id, name: device.name,
                                         host: device.host, port: device.port, modelName: nil))
        // connect sets .connecting synchronously; skip only the unused initial .disconnected state.
        observeSession(manager, token: generation)
    }

    func disconnect() {
        generation += 1
        let previous = session
        session = nil
        previous?.disconnect()
    }

    func submitPIN(_ pin: String) {
        session?.submitPIN(pin)
    }

    func send(_ command: RemoteCommand) {
        guard let session, session.connectionStatus == .connected else { return }
        let button: CompanionButton = switch command {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .select: .select
        case .back: .menu
        case .home: .home
        case .playPause: .playPause
        case .volumeDown: .volumeDown
        case .volumeUp: .volumeUp
        }
        session.pressButton(button)
    }

    func fetchApps(completion: @escaping (Result<[RemoteApp], Error>) -> Void) {
        guard let manager = session, manager.connectionStatus == .connected else {
            completion(.failure(RemoteAppTransportError.notConnected))
            return
        }
        let token = generation
        manager.fetchLaunchableApps { [weak self, weak manager] result in
            guard let self, let manager, token == self.generation, self.session === manager else { return }
            completion(result.map { $0.map { RemoteApp(id: $0.bundleID, name: $0.name) } })
        }
    }

    func launchApp(bundleID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let manager = session, manager.connectionStatus == .connected else {
            completion(.failure(RemoteAppTransportError.notConnected))
            return
        }
        let token = generation
        manager.requestAppLaunch(bundleID: bundleID) { [weak self, weak manager] result in
            guard let self, let manager, token == self.generation, self.session === manager else { return }
            completion(result)
        }
    }

    private func observeDevices(token: Int) {
        guard scanning, token == scanGeneration else { return }
        let devices = withObservationTracking {
            scanner.discoveredDevices
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeDevices(token: token) }
        }
        onDevicesChanged?(devices.map {
            RemoteDevice(id: $0.id, name: $0.name, host: $0.host, port: $0.port)
        })
    }

    private func observeSession(_ manager: AppleTVManager, token: Int) {
        guard token == generation, session === manager else { return }
        let status = withObservationTracking {
            manager.connectionStatus
        } onChange: { [weak self, weak manager] in
            Task { @MainActor [weak self, weak manager] in
                guard let manager else { return }
                self?.observeSession(manager, token: token)
            }
        }
        switch status {
        case .disconnected: onPhaseChanged?(.failed("Disconnected from Apple TV. Try reconnecting."))
        case .connecting: onPhaseChanged?(.connecting)
        case .pairing: onPhaseChanged?(.pairing)
        case .connected: onPhaseChanged?(.connected)
        case .error(let message): onPhaseChanged?(.failed(message))
        }
    }
}

private enum RemoteAppTransportError: LocalizedError {
    case notConnected
    var errorDescription: String? { "Connect to an Apple TV to use its apps." }
}

/// Supplies sample rooms and apps for offline previews.
@MainActor
final class DemoTransport: RemoteTransport {
    var onDevicesChanged: (([RemoteDevice]) -> Void)?
    var onPhaseChanged: ((RemotePhase) -> Void)?
    func startScanning() {
        onDevicesChanged?([
            RemoteDevice(id: "demo-living", name: "Living Room"),
            RemoteDevice(id: "demo-bedroom", name: "Bedroom"),
            RemoteDevice(id: "demo-den", name: "Den")
        ])
    }
    func refreshScanning() { startScanning() }
    func stopScanning() {}
    func connect(to device: RemoteDevice) { onPhaseChanged?(.connected) }
    func submitPIN(_ pin: String) {}
    func disconnect() {}
    func send(_ command: RemoteCommand) {}
    func fetchApps(completion: @escaping (Result<[RemoteApp], Error>) -> Void) {
        completion(.success([
            RemoteApp(id: "com.apple.TVWatchList", name: "Apple TV"),
            RemoteApp(id: "com.apple.TVMusic", name: "Music"),
            RemoteApp(id: "com.apple.TVPhotos", name: "Photos"),
            RemoteApp(id: "com.apple.TVSettings", name: "Settings"),
            RemoteApp(id: "com.apple.TVAppStore", name: "App Store"),
            RemoteApp(id: "com.apple.Fitness", name: "Fitness")
        ]))
    }
    func launchApp(bundleID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }
}
