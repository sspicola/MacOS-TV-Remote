import Foundation
import Observation

@MainActor @Observable
public final class RemoteModel {
    public private(set) var devices: [RemoteDevice] = []
    public private(set) var selectedDeviceID: String?
    public private(set) var selectedDeviceName = "Choose an Apple TV"
    public private(set) var phase: RemotePhase = .idle
    public private(set) var isScanning = false
    public var pin = ""
    public private(set) var lastAction: String?
    public let isDemo: Bool
    public private(set) var screen: RemoteScreen = .remote
    public private(set) var apps: [RemoteApp] = []
    public private(set) var appsState: AppListState = .idle
    public private(set) var launchingAppID: String?
    public private(set) var appLaunchError: String?
    public private(set) var lastLaunchedAppID: String?

    public var canSend: Bool { phase == .connected }

    @ObservationIgnored private let transport: RemoteTransport
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private let connectionTimeout: Duration
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var scanIndicatorTask: Task<Void, Never>?
    @ObservationIgnored private var acceptsSessionUpdates = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var shouldAutoConnect = true
    @ObservationIgnored private var selectedDevice: RemoteDevice?
    @ObservationIgnored private var lastSuccessfulID: String?
    @ObservationIgnored private var reconnectAfterWake = false
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var appListRequest = 0
    @ObservationIgnored private var appLaunchRequest = 0

    public init(transport: RemoteTransport, preferences: UserDefaults = .standard,
                isDemo: Bool = false, connectionTimeout: Duration = .seconds(20)) {
        self.transport = transport
        self.preferences = preferences
        self.isDemo = isDemo
        self.connectionTimeout = connectionTimeout
        self.lastSuccessfulID = preferences.string(forKey: "lastConnectedTV")
        transport.onDevicesChanged = { [weak self] devices in self?.updateDevices(devices) }
        transport.onPhaseChanged = { [weak self] phase in self?.receive(phase) }
    }

    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        isScanning = true
        transport.startScanning()
        resetScanIndicator()
    }

    public func refresh() {
        if !hasStarted { start(); return }
        isScanning = true
        transport.refreshScanning()
        resetScanIndicator()
    }

    public func selectDevice(id: String) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        if selectedDeviceID == id, phase == .connected { return }
        connect(device)
    }

    private func connect(_ device: RemoteDevice) {
        attempt += 1
        timeoutTask?.cancel()
        acceptsSessionUpdates = false
        resetApps()
        transport.disconnect()
        shouldAutoConnect = false
        selectedDevice = device
        selectedDeviceID = device.id
        selectedDeviceName = device.name
        pin = ""
        lastAction = nil
        phase = .connecting
        acceptsSessionUpdates = true
        // Start the timeout before the transport can report a result.
        armTimeout(connectionTimeout)
        transport.connect(to: device)
    }

    public func submitPIN() {
        guard phase == .pairing, pin.utf8.count == 4,
              pin.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
        let submittedPIN = pin
        pin = ""
        phase = .verifying
        armTimeout(connectionTimeout)
        transport.submitPIN(submittedPIN)
    }

    public func cancelConnection() {
        attempt += 1
        timeoutTask?.cancel()
        acceptsSessionUpdates = false
        resetApps()
        transport.disconnect()
        shouldAutoConnect = false
        phase = .idle
        pin = ""
        lastAction = nil
    }

    public func reconnect() {
        guard let device = devices.first(where: { $0.id == selectedDeviceID }) ?? selectedDevice else {
            refresh()
            return
        }
        connect(device)
    }

    public func send(_ command: RemoteCommand) {
        guard canSend else { return }
        transport.send(command)
        // Button presses have no TV-side acknowledgement.
        lastAction = command.label
    }

    public func showScreen(_ screen: RemoteScreen) {
        self.screen = screen
        if screen == .apps { loadApps() }
    }

    public func loadApps(force: Bool = false) {
        guard canSend else { return }
        if !force, appsState != .idle { return }
        appListRequest += 1
        let request = appListRequest
        let session = attempt
        appsState = .loading
        appLaunchError = nil
        transport.fetchApps { [weak self] result in
            guard let self, self.canSend, self.attempt == session,
                  self.appListRequest == request else { return }
            switch result {
            case .success(let returnedApps):
                let validApps = returnedApps.filter { !$0.id.isEmpty && !$0.name.isEmpty }
                let unique = Dictionary(validApps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.apps = unique.values.sorted {
                    let order = $0.name.localizedStandardCompare($1.name)
                    return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                }
                self.appsState = .loaded
            case .failure(let error):
                self.appsState = .failed(error.localizedDescription)
            }
        }
    }

    public func launchApp(id: String) {
        guard canSend, appsState == .loaded, launchingAppID == nil,
              let app = apps.first(where: { $0.id == id }) else { return }
        appLaunchRequest += 1
        let request = appLaunchRequest
        let session = attempt
        launchingAppID = id
        appLaunchError = nil
        lastLaunchedAppID = nil
        transport.launchApp(bundleID: id) { [weak self] result in
            guard let self, self.canSend, self.attempt == session,
                  self.appLaunchRequest == request else { return }
            self.launchingAppID = nil
            switch result {
            case .success:
                self.lastLaunchedAppID = id
                self.lastAction = "Open \(app.name)"
            case .failure(let error):
                self.appLaunchError = error.localizedDescription
            }
        }
    }

    private func resetApps() {
        appListRequest += 1
        appLaunchRequest += 1
        apps = []
        appsState = .idle
        launchingAppID = nil
        appLaunchError = nil
        lastLaunchedAppID = nil
    }

    public func prepareForSleep() {
        reconnectAfterWake = phase == .connected
        cancelConnection()
        transport.stopScanning()
        scanIndicatorTask?.cancel()
        isScanning = false
    }

    public func resumeAfterWake() {
        guard hasStarted else { return }
        transport.startScanning()
        isScanning = true
        resetScanIndicator()
        if reconnectAfterWake {
            reconnectAfterWake = false
            reconnect()
        }
    }

    public func stop() {
        cancelConnection()
        transport.stopScanning()
        scanIndicatorTask?.cancel()
        isScanning = false
        hasStarted = false
    }

    private func updateDevices(_ discovered: [RemoteDevice]) {
        var unique = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        if let selectedDevice {
            if let refreshedDevice = unique[selectedDevice.id] {
                self.selectedDevice = refreshedDevice
                selectedDeviceName = refreshedDevice.name
            } else {
                // Keep the selected TV visible while Bonjour briefly loses it.
                unique[selectedDevice.id] = selectedDevice
            }
        }
        devices = unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if shouldAutoConnect, let lastSuccessfulID,
           let device = unique[lastSuccessfulID] {
            connect(device)
        }
    }

    private func receive(_ next: RemotePhase) {
        guard selectedDevice != nil, acceptsSessionUpdates else { return }
        if phase == .verifying, next == .pairing || next == .connecting { return }
        phase = next
        if next != .connected { resetApps() }
        switch next {
        case .connected:
            timeoutTask?.cancel()
            pin = ""
            lastSuccessfulID = selectedDeviceID
            if !isDemo { preferences.set(selectedDeviceID, forKey: "lastConnectedTV") }
            if screen == .apps { loadApps() }
        case .pairing:
            armTimeout(.seconds(120))
        case .connecting:
            armTimeout(connectionTimeout)
        case .failed, .idle:
            timeoutTask?.cancel()
            pin = ""
            lastAction = nil
            acceptsSessionUpdates = false
            transport.disconnect()
        case .verifying:
            armTimeout(connectionTimeout)
        }
    }

    private func armTimeout(_ duration: Duration) {
        timeoutTask?.cancel()
        let token = attempt
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, token == self.attempt, self.phase != .connected else { return }
            let message = self.phase == .pairing
                ? "Pairing timed out. Try again to get a new code on your TV."
                : "Couldn’t connect. Check that your Mac and Apple TV are on the same network, then try again."
            self.acceptsSessionUpdates = false
            self.resetApps()
            self.transport.disconnect()
            self.phase = .failed(message)
            self.pin = ""
        }
    }

    private func resetScanIndicator() {
        scanIndicatorTask?.cancel()
        scanIndicatorTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.isScanning = false
        }
    }
}
