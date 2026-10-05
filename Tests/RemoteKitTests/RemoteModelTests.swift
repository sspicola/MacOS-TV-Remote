import Foundation
import Testing
@testable import RemoteKit

@Suite("Remote model")
@MainActor
struct RemoteModelTests {
    private let livingRoom = RemoteDevice(id: "living-room", name: "Living Room")
    private let bedroom = RemoteDevice(id: "bedroom", name: "Bedroom")

    @Test("Discovery deduplicates by ID, keeps updated details, and sorts room names")
    func discovery() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.model.start()
        fixture.model.start()
        let old = RemoteDevice(id: "den", name: "Old Name", host: "old.local")
        let updated = RemoteDevice(id: "den", name: "Den", host: "new.local")
        fixture.transport.discover([livingRoom, old, bedroom, updated])

        #expect(fixture.model.devices == [bedroom, updated, livingRoom])
        #expect(fixture.transport.startCount == 1)
        #expect(fixture.model.isScanning)
        #expect(fixture.transport.connections.isEmpty)
        #expect(fixture.model.selectedDeviceID == nil)
        #expect(fixture.model.phase == .idle)

        fixture.model.refresh()
        #expect(fixture.transport.refreshCount == 1)
    }

    @Test("Only a successful connection replaces the remembered TV")
    func remembersOnlySuccessfulConnection() {
        let fixture = Fixture(rememberedID: "previous-tv")
        defer { fixture.close() }
        fixture.transport.discover([livingRoom, bedroom])
        fixture.model.selectDevice(id: "missing")
        #expect(fixture.transport.connections.isEmpty)

        fixture.model.selectDevice(id: livingRoom.id)
        #expect(fixture.preferences.string(forKey: "lastConnectedTV") == "previous-tv")
        fixture.transport.report(.failed("Unavailable"))
        #expect(fixture.preferences.string(forKey: "lastConnectedTV") == "previous-tv")

        fixture.model.selectDevice(id: bedroom.id)
        fixture.transport.report(.connected)
        #expect(fixture.preferences.string(forKey: "lastConnectedTV") == bedroom.id)
        #expect(fixture.model.selectedDeviceName == bedroom.name)
        #expect(fixture.model.canSend)
    }

    @Test("Discovery reconnects a remembered TV once when it appears")
    func reconnectsRememberedTV() {
        let fixture = Fixture(rememberedID: livingRoom.id)
        defer { fixture.close() }
        fixture.model.start()
        fixture.transport.discover([bedroom])
        #expect(fixture.transport.connections.isEmpty)

        fixture.transport.discover([bedroom, livingRoom])
        fixture.transport.discover([livingRoom])
        #expect(fixture.transport.connections == [livingRoom])
        #expect(fixture.model.phase == .connecting)
        #expect(!fixture.model.canSend)
    }

    @Test("Switching TVs clears sensitive and transient state and gates commands")
    func switchTVs() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transport.discover([livingRoom, bedroom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.connected)
        fixture.model.send(.playPause)
        fixture.model.pin = "1234"
        fixture.model.selectDevice(id: bedroom.id)

        #expect(fixture.model.selectedDeviceID == bedroom.id)
        #expect(fixture.model.selectedDeviceName == bedroom.name)
        #expect(fixture.model.phase == .connecting)
        #expect(fixture.model.pin.isEmpty)
        #expect(fixture.model.lastAction == nil)
        #expect(!fixture.model.canSend)
        fixture.model.send(.volumeUp)
        #expect(fixture.transport.commands == [.playPause])

        fixture.transport.report(.connected)
        fixture.model.send(.volumeDown)
        #expect(fixture.transport.commands == [.playPause, .volumeDown])
        #expect(fixture.transport.connections == [livingRoom, bedroom])
    }

    @Test("A briefly missing active TV stays in the picker")
    func preservesSelectedTVAcrossDiscoveryChanges() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transport.discover([livingRoom, bedroom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.connected)
        fixture.transport.discover([bedroom])

        #expect(fixture.model.devices == [bedroom, livingRoom])
        #expect(fixture.model.selectedDeviceID == livingRoom.id)
        #expect(fixture.model.phase == .connected)
        fixture.model.selectDevice(id: livingRoom.id)
        #expect(fixture.transport.connections == [livingRoom])
    }

    @Test("All controls, including volume, forward exactly one command when connected")
    func commandForwarding() {
        let fixture = Fixture()
        defer { fixture.close() }
        for command in RemoteCommand.allCases { fixture.model.send(command) }
        #expect(fixture.transport.commands.isEmpty)
        #expect(fixture.model.lastAction == nil)
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.connected)

        for command in RemoteCommand.allCases {
            fixture.model.send(command)
            #expect(fixture.model.lastAction == command.label)
        }
        #expect(fixture.transport.commands == RemoteCommand.allCases)
    }

    @Test("Rediscovery refreshes the selected TV name and address used for reconnect")
    func refreshesSelectedDeviceDetails() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.connected)
        let updated = RemoteDevice(id: livingRoom.id, name: "Family Room",
                                   host: "192.168.1.42", port: 49153)
        fixture.transport.discover([updated])
        #expect(fixture.model.selectedDeviceName == updated.name)
        #expect(fixture.transport.connections == [livingRoom])

        fixture.transport.discover([])
        #expect(fixture.model.devices == [updated])
        fixture.model.reconnect()
        #expect(fixture.transport.connections == [livingRoom, updated])
    }

    @Test("Automatic reconnect uses the latest discovered details for a duplicate ID")
    func autoConnectUsesDeduplicatedDevice() {
        let fixture = Fixture(rememberedID: livingRoom.id)
        defer { fixture.close() }
        let updated = RemoteDevice(id: livingRoom.id, name: "Family Room",
                                   host: "192.168.1.42", port: 49153)
        fixture.transport.discover([livingRoom, updated])
        #expect(fixture.model.devices == [updated])
        #expect(fixture.transport.connections == [updated])
        #expect(fixture.model.selectedDeviceName == updated.name)
    }

    @Test("Pairing accepts exactly four ASCII digits and clears the submitted PIN")
    func validatesPIN() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.model.pin = "1234"
        fixture.model.submitPIN()
        #expect(fixture.transport.submittedPINs.isEmpty)
        fixture.transport.report(.pairing)

        for invalidPIN in ["", "123", "12345", "1a34", " 123", "１２３４", "١٢٣٤"] {
            fixture.model.pin = invalidPIN
            fixture.model.submitPIN()
            #expect(fixture.transport.submittedPINs.isEmpty)
            #expect(fixture.model.phase == .pairing)
        }

        fixture.model.pin = "0427"
        fixture.model.submitPIN()
        #expect(fixture.transport.submittedPINs == ["0427"])
        #expect(fixture.model.pin.isEmpty)
        #expect(fixture.model.phase == .verifying)
        #expect(!fixture.model.canSend)
        fixture.model.submitPIN()
        fixture.transport.report(.pairing)
        fixture.transport.report(.connecting)
        #expect(fixture.transport.submittedPINs == ["0427"])
        #expect(fixture.model.phase == .verifying)
    }

    @Test("A failed pairing clears the entered PIN")
    func pairingFailureClearsPIN() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.pairing)
        fixture.model.pin = "9876"
        fixture.transport.report(.failed("Incorrect code"))

        #expect(fixture.model.pin.isEmpty)
        #expect(fixture.model.phase == .failed("Incorrect code"))
        #expect(!fixture.model.canSend)
        #expect(fixture.preferences.string(forKey: "lastConnectedTV") == nil)
    }

    @Test("Cancel closes pairing, disables commands, and prevents automatic retry")
    func cancellation() {
        let fixture = Fixture(rememberedID: livingRoom.id)
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.transport.report(.pairing)
        fixture.model.pin = "1234"
        fixture.model.cancelConnection()
        fixture.model.submitPIN()
        fixture.model.send(.select)
        fixture.transport.discover([livingRoom])

        #expect(fixture.model.phase == .idle)
        #expect(fixture.model.pin.isEmpty)
        #expect(fixture.model.lastAction == nil)
        #expect(!fixture.model.canSend)
        #expect(fixture.transport.submittedPINs.isEmpty)
        #expect(fixture.transport.commands.isEmpty)
        #expect(fixture.transport.connections == [livingRoom])
        #expect(fixture.transport.disconnectCount == 2)
    }

    @Test("A late transport callback cannot revive a cancelled connection")
    func cancellationRejectsLateCallback() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.model.cancelConnection()
        fixture.transport.report(.connected)
        fixture.model.send(.volumeUp)

        #expect(fixture.model.phase == .idle)
        #expect(!fixture.model.canSend)
        #expect(fixture.transport.commands.isEmpty)
        #expect(fixture.preferences.string(forKey: "lastConnectedTV") == nil)
    }

    @Test("An unanswered connection times out and disconnects")
    func connectionTimesOut() async throws {
        let fixture = Fixture(timeout: .milliseconds(20))
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.model.pin = "1234"
        try await Task.sleep(for: .milliseconds(60))

        guard case .failed(let message) = fixture.model.phase else {
            Issue.record("Expected a connection timeout, got \(fixture.model.phase)")
            return
        }
        #expect(message.contains("Couldn’t connect"))
        #expect(fixture.model.pin.isEmpty)
        #expect(!fixture.model.canSend)
        #expect(fixture.transport.disconnectCount == 2)
        fixture.transport.report(.connected)
        fixture.model.send(.select)
        #expect(fixture.transport.commands.isEmpty)
        #expect(fixture.model.phase == .failed(message))
        #expect(fixture.preferences.string(forKey: "lastConnectedTV") == nil)
    }

    @Test("A transport disconnect clears pairing and rejects late connection callbacks")
    func transportDisconnectClosesSession() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.pairing)
        fixture.model.pin = "1234"
        fixture.transport.report(.idle)

        #expect(fixture.model.phase == .idle)
        #expect(fixture.model.pin.isEmpty)
        #expect(fixture.transport.disconnectCount == 2)
        fixture.transport.report(.connected)
        fixture.model.send(.volumeUp)
        #expect(fixture.model.phase == .idle)
        #expect(fixture.transport.commands.isEmpty)
        #expect(fixture.preferences.string(forKey: "lastConnectedTV") == nil)
    }

    @Test("Connection failure clears the previous action")
    func failureClearsPreviousAction() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.connected)
        fixture.model.send(.home)
        fixture.transport.report(.failed("Connection lost"))

        #expect(fixture.model.phase == .failed("Connection lost"))
        #expect(fixture.model.lastAction == nil)
        #expect(!fixture.model.canSend)
    }

    @Test("A successful connection cancels its timeout")
    func successCancelsTimeout() async throws {
        let fixture = Fixture(timeout: .milliseconds(20))
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.connected)
        try await Task.sleep(for: .milliseconds(60))

        #expect(fixture.model.phase == .connected)
        #expect(fixture.transport.disconnectCount == 1)
    }

    @Test("Cancelling an attempt cancels its timeout")
    func cancellationCancelsTimeout() async throws {
        let fixture = Fixture(timeout: .milliseconds(20))
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.model.cancelConnection()
        try await Task.sleep(for: .milliseconds(60))

        #expect(fixture.model.phase == .idle)
        #expect(fixture.transport.disconnectCount == 2)
    }

    @Test("Wake reconnects the previously connected TV, only once")
    func sleepAndWakeReconnect() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.model.start()
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.connected)
        fixture.model.send(.home)
        fixture.model.prepareForSleep()

        #expect(fixture.model.phase == .idle)
        #expect(!fixture.model.isScanning)
        #expect(!fixture.model.canSend)
        #expect(fixture.model.lastAction == nil)
        #expect(fixture.transport.stopCount == 1)

        fixture.model.resumeAfterWake()
        #expect(fixture.model.phase == .connecting)
        #expect(fixture.model.isScanning)
        #expect(fixture.transport.startCount == 2)
        #expect(fixture.transport.connections == [livingRoom, livingRoom])
        fixture.model.resumeAfterWake()
        #expect(fixture.transport.connections.count == 2)
    }

    @Test("Wake does not reconnect an unfinished pairing")
    func sleepDoesNotResumePairing() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.model.start()
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.pairing)
        fixture.model.pin = "1234"
        fixture.model.prepareForSleep()
        fixture.model.resumeAfterWake()

        #expect(fixture.model.phase == .idle)
        #expect(fixture.model.pin.isEmpty)
        #expect(fixture.model.isScanning)
        #expect(fixture.transport.connections == [livingRoom])
    }

    @Test("Wake does nothing before the model has started")
    func wakeBeforeStart() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.model.resumeAfterWake()
        #expect(fixture.transport.startCount == 0)
        #expect(!fixture.model.isScanning)
        #expect(fixture.transport.connections.isEmpty)
    }

    @Test("Demo connections preserve the real remembered TV")
    func demoDoesNotPersistSelection() {
        let fixture = Fixture(rememberedID: "real-tv", isDemo: true)
        defer { fixture.close() }
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.connected)
        #expect(fixture.preferences.string(forKey: "lastConnectedTV") == "real-tv")
    }
}

@Suite("Apple TV apps")
@MainActor
struct RemoteAppsModelTests {
    private let livingRoom = RemoteDevice(id: "living-room", name: "Living Room")
    private let bedroom = RemoteDevice(id: "bedroom", name: "Bedroom")
    private let netflix = RemoteApp(id: "com.netflix.Netflix", name: "Netflix")
    private let youtube = RemoteApp(id: "com.google.ios.youtube", name: "YouTube")

    @Test("Apps start empty and cannot load or launch while disconnected")
    func appsRequireConnection() {
        let fixture = Fixture()
        defer { fixture.close() }
        #expect(fixture.model.screen == .remote)
        #expect(fixture.model.apps.isEmpty)
        #expect(fixture.model.appsState == .idle)
        #expect(fixture.model.launchingAppID == nil)
        #expect(fixture.model.lastLaunchedAppID == nil)
        #expect(fixture.model.appLaunchError == nil)

        fixture.model.showScreen(.apps)
        fixture.model.loadApps(force: true)
        fixture.model.launchApp(id: netflix.id)
        #expect(fixture.model.screen == .apps)
        #expect(fixture.model.appsState == .idle)
        #expect(fixture.transport.appFetchCompletions.isEmpty)
        #expect(fixture.transport.appLaunches.isEmpty)
    }

    @Test("Connecting while Apps is selected loads that TV's apps")
    func connectionLoadsVisibleApps() {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.model.showScreen(.apps)
        fixture.transport.discover([livingRoom])
        fixture.model.selectDevice(id: livingRoom.id)
        #expect(fixture.transport.appFetchCompletions.isEmpty)
        fixture.transport.report(.connected)

        #expect(fixture.model.screen == .apps)
        #expect(fixture.model.appsState == .loading)
        #expect(fixture.transport.appFetchCompletions.count == 1)
        fixture.transport.completeApps(.success([netflix]))
        #expect(fixture.model.apps == [netflix])
        #expect(fixture.model.appsState == .loaded)
    }

    @Test("Opening Apps loads once, deduplicates IDs, sorts names, and caches the list")
    func fetchesAndCachesApps() {
        let fixture = connectedFixture()
        defer { fixture.close() }
        #expect(fixture.transport.appFetchCompletions.isEmpty)
        fixture.model.showScreen(.apps)
        fixture.model.showScreen(.apps)
        fixture.model.loadApps()
        #expect(fixture.model.appsState == .loading)
        #expect(fixture.transport.appFetchCompletions.count == 1)

        let missingID = RemoteApp(id: "", name: "Invalid")
        let missingName = RemoteApp(id: "missing.name", name: "")
        fixture.transport.completeApps(.success([youtube, netflix, netflix, missingID, missingName]))
        #expect(fixture.model.apps == [netflix, youtube])
        #expect(fixture.model.appsState == .loaded)
        fixture.model.showScreen(.remote)
        fixture.model.showScreen(.apps)
        fixture.model.loadApps()
        #expect(fixture.transport.appFetchCompletions.count == 1)

        fixture.model.loadApps(force: true)
        #expect(fixture.transport.appFetchCompletions.count == 2)
        #expect(fixture.model.appsState == .loading)
        fixture.model.launchApp(id: netflix.id)
        #expect(fixture.transport.appLaunches.isEmpty)
        fixture.transport.completeApps(.success([youtube]), request: 1)
        #expect(fixture.model.apps == [youtube])
        #expect(fixture.model.appsState == .loaded)
    }

    @Test("An empty app list is a completed result and is not repeatedly fetched")
    func emptyAppListIsLoaded() {
        let fixture = connectedFixture()
        defer { fixture.close() }
        fixture.model.showScreen(.apps)
        fixture.transport.completeApps(.success([]))
        #expect(fixture.model.apps.isEmpty)
        #expect(fixture.model.appsState == .loaded)
        fixture.model.showScreen(.remote)
        fixture.model.showScreen(.apps)
        #expect(fixture.transport.appFetchCompletions.count == 1)
    }

    @Test("App list errors preserve remote control and support retry")
    func appFetchFailureIsRecoverable() {
        let fixture = connectedFixture()
        defer { fixture.close() }
        fixture.model.showScreen(.apps)
        fixture.transport.completeApps(.failure(AppTestError("Could not load apps")))
        guard case .failed(let message) = fixture.model.appsState else {
            Issue.record("Expected an app-list failure, got \(fixture.model.appsState)")
            return
        }
        #expect(!message.isEmpty)
        #expect(fixture.model.phase == .connected)
        #expect(fixture.model.canSend)
        #expect(fixture.model.appLaunchError == nil)
        fixture.model.send(.home)
        #expect(fixture.transport.commands == [.home])

        fixture.model.loadApps(force: true)
        #expect(fixture.model.appsState == .loading)
        fixture.transport.completeApps(.success([netflix]), request: 1)
        #expect(fixture.model.apps == [netflix])
        #expect(fixture.model.appsState == .loaded)
    }

    @Test("A forced reload ignores successes and failures from an older fetch")
    func reloadRejectsOlderFetch() {
        let fixture = connectedFixture()
        defer { fixture.close() }
        fixture.model.showScreen(.apps)
        fixture.model.loadApps(force: true)
        #expect(fixture.transport.appFetchCompletions.count == 2)
        fixture.transport.completeApps(.success([youtube]), request: 1)
        fixture.transport.completeApps(.success([netflix]), request: 0)
        fixture.transport.completeApps(.failure(AppTestError("Old request failed")), request: 0)

        #expect(fixture.model.apps == [youtube])
        #expect(fixture.model.appsState == .loaded)
        #expect(fixture.model.phase == .connected)
    }

    @Test("Switching TVs clears apps and rejects the previous TV's fetch")
    func switchRejectsPreviousTVApps() {
        let fixture = connectedFixture()
        defer { fixture.close() }
        fixture.model.showScreen(.apps)
        fixture.model.selectDevice(id: bedroom.id)
        #expect(fixture.model.apps.isEmpty)
        #expect(fixture.model.appsState == .idle)
        #expect(fixture.model.screen == .apps)
        fixture.transport.report(.connected)
        #expect(fixture.transport.appFetchCompletions.count == 2)
        fixture.transport.completeApps(.success([youtube]), request: 1)
        fixture.transport.completeApps(.success([netflix]), request: 0)

        #expect(fixture.model.selectedDeviceID == bedroom.id)
        #expect(fixture.model.apps == [youtube])
        #expect(fixture.model.appsState == .loaded)
    }

    @Test("Launch requires a known app, sends its bundle ID, and prevents duplicate requests")
    func launchesKnownAppOnce() {
        let fixture = connectedFixture()
        defer { fixture.close() }
        fixture.model.showScreen(.apps)
        fixture.transport.completeApps(.success([netflix, youtube]))
        fixture.model.launchApp(id: "unknown.bundle")
        #expect(fixture.transport.appLaunches.isEmpty)
        fixture.model.launchApp(id: netflix.id)
        #expect(fixture.model.launchingAppID == netflix.id)
        #expect(fixture.model.lastLaunchedAppID == nil)
        #expect(fixture.model.lastAction == nil)
        fixture.model.launchApp(id: netflix.id)
        fixture.model.launchApp(id: youtube.id)
        #expect(fixture.transport.appLaunches.map(\.bundleID) == [netflix.id])

        fixture.transport.completeLaunch(.success(()))
        #expect(fixture.model.launchingAppID == nil)
        #expect(fixture.model.lastLaunchedAppID == netflix.id)
        #expect(fixture.model.lastAction == "Open Netflix")
        #expect(fixture.model.appLaunchError == nil)
        #expect(fixture.model.phase == .connected)
    }

    @Test("Launch errors preserve the TV connection and clear on a new attempt")
    func launchFailureCanRetry() {
        let fixture = connectedFixture()
        defer { fixture.close() }
        fixture.model.showScreen(.apps)
        fixture.transport.completeApps(.success([netflix]))
        fixture.model.launchApp(id: netflix.id)
        fixture.transport.completeLaunch(.failure(AppTestError("Could not open Netflix")))

        #expect(fixture.model.launchingAppID == nil)
        #expect(fixture.model.lastLaunchedAppID == nil)
        #expect(fixture.model.appLaunchError?.isEmpty == false)
        #expect(fixture.model.phase == .connected)
        #expect(fixture.model.canSend)
        #expect(fixture.model.appsState == .loaded)
        #expect(fixture.model.lastAction == nil)

        fixture.model.launchApp(id: netflix.id)
        #expect(fixture.model.appLaunchError == nil)
        #expect(fixture.model.launchingAppID == netflix.id)
        #expect(fixture.transport.appLaunches.count == 2)
        fixture.transport.completeLaunch(.success(()), request: 1)
        #expect(fixture.model.lastLaunchedAppID == netflix.id)
        #expect(fixture.model.lastAction == "Open Netflix")
    }

    @Test("Switching TVs clears launch state and ignores an old launch completion")
    func switchRejectsPreviousLaunch() {
        let fixture = connectedFixture()
        defer { fixture.close() }
        fixture.model.showScreen(.apps)
        fixture.transport.completeApps(.success([netflix]))
        fixture.model.launchApp(id: netflix.id)
        fixture.transport.completeLaunch(.success(()))
        fixture.model.launchApp(id: netflix.id)
        fixture.model.selectDevice(id: bedroom.id)

        #expect(fixture.model.apps.isEmpty)
        #expect(fixture.model.appsState == .idle)
        #expect(fixture.model.launchingAppID == nil)
        #expect(fixture.model.lastLaunchedAppID == nil)
        #expect(fixture.model.appLaunchError == nil)
        #expect(fixture.model.lastAction == nil)

        fixture.transport.report(.connected)
        fixture.transport.completeApps(.success([youtube]), request: 1)
        fixture.model.launchApp(id: youtube.id)
        fixture.transport.completeLaunch(.success(()), request: 1)
        #expect(fixture.model.launchingAppID == youtube.id)
        #expect(fixture.model.lastLaunchedAppID == nil)
        #expect(fixture.model.lastAction == nil)
        fixture.transport.completeLaunch(.success(()), request: 2)
        #expect(fixture.model.lastLaunchedAppID == youtube.id)
        #expect(fixture.model.lastAction == "Open YouTube")
    }

    @Test("Disconnect clears apps and invalidates pending requests", arguments: [false, true])
    func disconnectInvalidatesAppRequests(withFailure: Bool) {
        let fixture = connectedFixture()
        defer { fixture.close() }
        fixture.model.showScreen(.apps)
        fixture.transport.completeApps(.success([netflix]))
        fixture.model.launchApp(id: netflix.id)
        fixture.model.loadApps(force: true)
        if withFailure {
            fixture.transport.report(.failed("Connection lost"))
        } else {
            fixture.model.cancelConnection()
        }
        fixture.transport.completeApps(.success([youtube]), request: 1)
        fixture.transport.completeLaunch(.failure(AppTestError("Stale failure")))
        fixture.transport.completeLaunch(.success(()))
        fixture.model.launchApp(id: netflix.id)

        #expect(fixture.model.apps.isEmpty)
        #expect(fixture.model.appsState == .idle)
        #expect(fixture.model.launchingAppID == nil)
        #expect(fixture.model.lastLaunchedAppID == nil)
        #expect(fixture.model.appLaunchError == nil)
        #expect(fixture.model.lastAction == nil)
        #expect(!fixture.model.canSend)
        #expect(fixture.transport.appLaunches.count == 1)
        if withFailure {
            #expect(fixture.model.phase == .failed("Connection lost"))
        } else {
            #expect(fixture.model.phase == .idle)
        }
    }

    private func connectedFixture() -> Fixture {
        let fixture = Fixture()
        fixture.transport.discover([livingRoom, bedroom])
        fixture.model.selectDevice(id: livingRoom.id)
        fixture.transport.report(.connected)
        return fixture
    }
}

private struct AppTestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
private struct Fixture {
    let transport: FakeRemoteTransport
    let preferences: UserDefaults
    let model: RemoteModel
    private let suiteName: String

    init(rememberedID: String? = nil, isDemo: Bool = false,
         timeout: Duration = .seconds(20)) {
        suiteName = "RemoteModelTests.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suiteName)!
        preferences.removePersistentDomain(forName: suiteName)
        if let rememberedID { preferences.set(rememberedID, forKey: "lastConnectedTV") }
        transport = FakeRemoteTransport()
        model = RemoteModel(transport: transport, preferences: preferences,
                            isDemo: isDemo, connectionTimeout: timeout)
    }

    func close() {
        model.stop()
        preferences.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class FakeRemoteTransport: RemoteTransport {
    var onDevicesChanged: (([RemoteDevice]) -> Void)?
    var onPhaseChanged: ((RemotePhase) -> Void)?
    private(set) var startCount = 0
    private(set) var refreshCount = 0
    private(set) var stopCount = 0
    private(set) var disconnectCount = 0
    private(set) var connections: [RemoteDevice] = []
    private(set) var submittedPINs: [String] = []
    private(set) var commands: [RemoteCommand] = []
    private(set) var appFetchCompletions: [(Result<[RemoteApp], Error>) -> Void] = []
    private(set) var appLaunches: [(bundleID: String, completion: (Result<Void, Error>) -> Void)] = []

    func startScanning() { startCount += 1 }
    func refreshScanning() { refreshCount += 1 }
    func stopScanning() { stopCount += 1 }
    func connect(to device: RemoteDevice) { connections.append(device) }
    func submitPIN(_ pin: String) { submittedPINs.append(pin) }
    func disconnect() { disconnectCount += 1 }
    func send(_ command: RemoteCommand) { commands.append(command) }
    func fetchApps(completion: @escaping (Result<[RemoteApp], Error>) -> Void) {
        appFetchCompletions.append(completion)
    }
    func launchApp(bundleID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        appLaunches.append((bundleID, completion))
    }
    func completeApps(_ result: Result<[RemoteApp], Error>, request: Int = 0) {
        guard appFetchCompletions.indices.contains(request) else {
            Issue.record("No app fetch exists at index \(request)")
            return
        }
        appFetchCompletions[request](result)
    }
    func completeLaunch(_ result: Result<Void, Error>, request: Int = 0) {
        guard appLaunches.indices.contains(request) else {
            Issue.record("No app launch exists at index \(request)")
            return
        }
        appLaunches[request].completion(result)
    }
    func discover(_ devices: [RemoteDevice]) { onDevicesChanged?(devices) }
    func report(_ phase: RemotePhase) { onPhaseChanged?(phase) }
}
