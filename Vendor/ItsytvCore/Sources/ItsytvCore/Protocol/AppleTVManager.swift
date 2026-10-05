import Foundation
import CoreGraphics
import CryptoKit
import os.log

private let log = CoreLog(category: "Manager")

enum TouchMotionProfile {
    static let touchpadSize: Double = 1000
    static let center: Double = touchpadSize / 2
    static let defaultReferenceSize = CGSize(width: 200, height: 200)
    static let sampleInterval: TimeInterval = 1.0 / 60.0
    static let inertiaProjectionTime: CGFloat = 0.075
    static let inertiaMaxDistanceRatio: CGFloat = 0.9
    static let inertiaMinimumVelocity: CGFloat = 120
    static let inertiaSteps = 8

    static func sanitizeReferenceSize(_ referenceSize: CGSize) -> CGSize {
        CGSize(
            width: referenceSize.width > 0 ? referenceSize.width : defaultReferenceSize.width,
            height: referenceSize.height > 0 ? referenceSize.height : defaultReferenceSize.height
        )
    }

    static func virtualDelta(for pointDelta: CGPoint, referenceSize: CGSize) -> CGPoint {
        let reference = sanitizeReferenceSize(referenceSize)
        return CGPoint(
            x: pointDelta.x * CGFloat(touchpadSize) / reference.width,
            y: pointDelta.y * CGFloat(touchpadSize) / reference.height
        )
    }

    static func inertiaVirtualDeltas(for velocity: CGPoint, referenceSize: CGSize) -> [CGPoint] {
        guard hypot(velocity.x, velocity.y) >= inertiaMinimumVelocity else { return [] }

        let reference = sanitizeReferenceSize(referenceSize)
        let projectedPointDelta = CGPoint(
            x: clamp(
                velocity.x * inertiaProjectionTime,
                min: -reference.width * inertiaMaxDistanceRatio,
                max: reference.width * inertiaMaxDistanceRatio
            ),
            y: clamp(
                velocity.y * inertiaProjectionTime,
                min: -reference.height * inertiaMaxDistanceRatio,
                max: reference.height * inertiaMaxDistanceRatio
            )
        )

        var previous = CGPoint.zero
        var deltas: [CGPoint] = []
        deltas.reserveCapacity(inertiaSteps)

        for step in 1...inertiaSteps {
            let progress = CGFloat(step) / CGFloat(inertiaSteps)
            let eased = 1 - (1 - progress) * (1 - progress)
            let current = CGPoint(
                x: projectedPointDelta.x * eased,
                y: projectedPointDelta.y * eased
            )
            deltas.append(
                virtualDelta(
                    for: CGPoint(x: current.x - previous.x, y: current.y - previous.y),
                    referenceSize: reference
                )
            )
            previous = current
        }

        return deltas
    }

    private static func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}

/// Orchestrates the full lifecycle of connecting to an Apple TV:
/// discovery -> pair-setup (if needed) -> pair-verify -> encrypted commands.
@Observable
public final class AppleTVManager {
    /// Use an app-group `UserDefaults` instance when the app and widget extension
    /// need to share the last connected device across processes.
    public static func configurePersistence(userDefaults: UserDefaults) {
        LastConnectedDeviceStorage.userDefaults = userDefaults
    }

    public var connectionStatus: ConnectionStatus = .disconnected
    public var discoveredDevices: [AppleTVDevice] = []
    public var connectedDeviceName: String?
    /// Apple TV `tvOS` version reported in the `_systemInfo` reply (e.g. "26.5.0").
    /// `nil` until the handshake completes. Drives empty-state messaging in
    /// the apps grid since tvOS 26.5 beta silently drops the app-list fetch.
    public var osVersion: String?
    public var isScanning = false
    public var installedApps: [(bundleID: String, name: String)] = []
    public var keyboardFocused = false
    public var mrpManager = MRPManager()
    public var keyboardBlinkButton: CompanionButton = .select
    public var keyboardBlinkCounter = 0
    public var keyboardToggleCounter = 0
    public func triggerKeyboardBlink(_ button: CompanionButton) {
        keyboardBlinkButton = button
        keyboardBlinkCounter &+= 1
    }

    public var connectedDeviceID: String? { connectedDevice?.id }

    private var connection: CompanionConnection?
    private var pairSetup: PairSetup?
    private var partialCredentials: HAPCredentials?
    private var currentCredentials: HAPCredentials?
    private var connectedDevice: AppleTVDevice?

    /// Text input session state — kept alive while connected.
    private var textInputSessionUUID: Data?
    private var sentText = ""
    private var pendingCompanionCommands: [() -> Void] = []
    private var mrpRetryCount = 0
    private static let maxMRPRetries = 3
    private var isReconnecting = false
    private var companionRetryCount = 0
    private static let maxCompanionRetries = 3

    private let discovery = DeviceDiscovery()
    private let enableMediaRemote: Bool
    private var sessionGeneration: UInt64 = 0

    /// Call lifecycle and command methods on the main thread.
    /// Disable Media Remote for a minimal Companion button remote: no MRP,
    /// application list, touch session, or keyboard listener is started.
    public init(enableMediaRemote: Bool = true) {
        self.enableMediaRemote = enableMediaRemote
    }

    // MARK: - Discovery

    public func startScanning() {
        isScanning = true
        discovery.start { [weak self] devices in
            self?.discoveredDevices = devices
        }
    }

    public func refreshScanning() {
        discovery.refresh()
    }

    /// Returns all resolved Bonjour services (including filtered ones) for debugging.
    public func debugDiscoveryDump() -> [[String: Any]] {
        discovery.allResolvedServices()
    }

    public func stopScanning() {
        isScanning = false
        discovery.stop()
        discoveredDevices = []
    }

    // MARK: - Connection

    public func connect(to device: AppleTVDevice) {
        connect(to: device, preservingPendingCommands: false)
    }

    @discardableResult
    public func connectToLastConnectedDevice() -> Bool {
        guard let device = LastConnectedDeviceStorage.load() else { return false }
        connect(to: device, preservingPendingCommands: false)
        return true
    }

    /// Device ID of the most recently connected Apple TV (persisted across
    /// launches), or `nil` if none has ever connected.
    public var lastConnectedDeviceID: String? {
        LastConnectedDeviceStorage.load()?.id
    }

    private func connect(to device: AppleTVDevice, preservingPendingCommands: Bool) {
        disconnect(clearPendingCommands: !preservingPendingCommands)
        connectionStatus = .connecting
        self.connectedDevice = device
        self.connectedDeviceName = device.name
        LastConnectedDeviceStorage.save(device)

        let conn = CompanionConnection()
        self.connection = conn

        let generation = sessionGeneration
        installCompanionCallbacks(conn, generation: generation)

        // Credentials are keyed by the discovered Bonjour service name.
        if let credentials = KeychainStorage.load(for: device.id) {
            // Already paired — do pair-verify when connection is ready
            self.currentCredentials = credentials
            connectedDeviceName = device.name

            conn.onConnect = { [weak self, weak conn] in
                guard let self, self.isCurrent(conn, generation: generation) else { return }
                self.startPairVerify(credentials: credentials)
            }
            conn.connectToService(name: device.name)
        } else {
            // Need to pair first
            connectedDeviceName = device.name
            conn.onConnect = { [weak self, weak conn] in
                guard let self, let conn, self.isCurrent(conn, generation: generation) else { return }
                let setup = PairSetup(connection: conn)
                self.pairSetup = setup
                let m1Frame = setup.startPairing()
                conn.send(frame: m1Frame)
            }
            conn.connectToService(name: device.name)
        }
    }

    public func disconnect() {
        disconnect(clearPendingCommands: true)
    }

    private func disconnect(clearPendingCommands: Bool) {
        sessionGeneration &+= 1
        touchSequenceID &+= 1
        touchIsActive = false
        mrpManager.onDisconnect = nil
        mrpManager.onReady = nil
        mrpManager.onKeyboardFocusChange = nil
        mrpManager.disconnect()
        connection?.disconnect()
        connection = nil
        connectionStatus = .disconnected
        connectedDeviceName = nil
        connectedDevice = nil
        currentCredentials = nil
        pairSetup = nil
        partialCredentials = nil
        pendingM2 = nil
        pendingPairVerify = nil
        textInputSessionUUID = nil
        keyboardFocused = false
        sentText = ""
        mrpRetryCount = 0
        companionRetryCount = 0
        isReconnecting = false
        installedApps = []
        osVersion = nil
        if clearPendingCommands {
            pendingCompanionCommands.removeAll()
        }
    }

    // MARK: - Pairing

    public func submitPIN(_ pin: String) {
        guard connectionStatus == .pairing, let pairSetup, let connection else { return }

        // Pairing is exposed only once the current M2 challenge is ready.
        guard let m2 = pendingM2 else {
            connectionStatus = .error("No challenge received from Apple TV")
            return
        }

        do {
            let m3Frame = try pairSetup.processChallengeAndProve(m2Frame: m2, pin: pin)
            pendingM2 = nil
            connectionStatus = .connecting
            connection.send(frame: m3Frame)
        } catch {
            connectionStatus = .error(error.localizedDescription)
        }
    }

    // MARK: - Commands

    /// Toggle mute on/off via MRP HID event.
    /// Works with soundbars/receivers connected via HDMI-CEC.
    public func toggleMute() {
        mrpManager.toggleMute()
    }

    public func pressButton(_ button: CompanionButton, action: InputAction = .click) {
        performOrQueueCompanionCommand { [weak self] in
            guard let self else { return }
            switch action {
            case .click:
                let hold: TimeInterval = button == .siri ? 1.0 : 0.05
                self.connection?.pressButton(button, holdDuration: hold)
            case .doubleClick:
                self.connection?.doubleTapButton(button)
            case .hold:
                self.connection?.holdButton(button)
            }
        }
    }

    /// Send a touchpad swipe in the given direction, scaled by travel fraction (0–1).
    public func swipe(_ direction: SwipeDirection, fraction: CGFloat = 0.5) {
        performOrQueueCompanionCommand { [weak self] in
            guard let self else { return }
            let center: Int64 = 500
            // Short swipe ~80 units (single item), full-pad swipe ~400 units
            let distance = Int64(80 + 320 * min(1, max(0, fraction)))
            let (endX, endY): (Int64, Int64) = switch direction {
            case .up:    (center, center - distance)
            case .down:  (center, center + distance)
            case .left:  (center - distance, center)
            case .right: (center + distance, center)
            }
            self.connection?.sendSwipe(startX: center, startY: center, endX: endX, endY: endY, durationMs: 150)
        }
    }

    // MARK: - Real-time touch streaming

    private var touchLastNormalizedDx: CGFloat = 0
    private var touchLastNormalizedDy: CGFloat = 0
    private var touchLastTranslation: CGPoint = .zero
    private var touchReferenceSize: CGSize = TouchMotionProfile.defaultReferenceSize
    private var touchVirtualX: Double = TouchMotionProfile.center
    private var touchVirtualY: Double = TouchMotionProfile.center
    private var touchLastSendTime: TimeInterval = 0
    private var touchSequenceID: UInt64 = 0
    private var touchIsActive = false

    /// Begin a touch at the center of the virtual touchpad.
    public func touchBegan() {
        touchBegan(referenceSize: TouchMotionProfile.defaultReferenceSize)
    }

    /// Begin a touch using the provided reference touch surface size in points.
    public func touchBegan(referenceSize: CGSize) {
        touchSequenceID &+= 1

        if touchIsActive {
            finishTouch()
        }

        touchReferenceSize = TouchMotionProfile.sanitizeReferenceSize(referenceSize)
        touchLastNormalizedDx = 0
        touchLastNormalizedDy = 0
        touchLastTranslation = .zero
        touchVirtualX = TouchMotionProfile.center
        touchVirtualY = TouchMotionProfile.center
        touchLastSendTime = 0
        touchIsActive = true
        connection?.sendTouchEvent(
            x: Int64(TouchMotionProfile.center),
            y: Int64(TouchMotionProfile.center),
            phase: .press
        )
    }

    /// Stream a touch move. `translation` is the cumulative drag offset in points.
    public func touchMoved(translation: CGPoint) {
        guard touchIsActive else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - touchLastSendTime >= TouchMotionProfile.sampleInterval else { return }
        touchLastSendTime = now

        applyTouchTranslation(translation)
    }

    /// Compatibility overload for clients that still send cumulative normalized offsets.
    public func touchMoved(dx: CGFloat, dy: CGFloat) {
        guard touchIsActive else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - touchLastSendTime >= TouchMotionProfile.sampleInterval else { return }
        touchLastSendTime = now

        applyNormalizedTouchTranslation(dx: dx, dy: dy)
    }

    /// End the touch at the current position, preserving the last finger movement and velocity.
    public func touchEnded(translation: CGPoint, velocity: CGPoint) {
        guard touchIsActive else { return }

        applyTouchTranslation(translation)

        let inertiaDeltas = TouchMotionProfile.inertiaVirtualDeltas(
            for: velocity,
            referenceSize: touchReferenceSize
        )
        guard !inertiaDeltas.isEmpty else {
            finishTouch()
            return
        }

        let sequenceID = touchSequenceID
        continueTouchInertia(with: inertiaDeltas, index: 0, sequenceID: sequenceID)
    }

    public func touchEnded(dx: CGFloat, dy: CGFloat) {
        guard touchIsActive else { return }
        applyNormalizedTouchTranslation(dx: dx, dy: dy)
        finishTouch()
    }

    public func launchApp(bundleID: String) {
        performOrQueueCompanionCommand { [weak self] in
            self?.requestAppLaunch(bundleID: bundleID) { result in
                if case .failure(let error) = result {
                    log.warning("App launch failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Request the current launchable app list over Companion, including in
    /// Companion-only mode. A valid empty list succeeds; errors never become [].
    /// Completion runs on main and is suppressed after this session is retired.
    public func fetchLaunchableApps(
        completion: @escaping (Result<[(bundleID: String, name: String)], Swift.Error>) -> Void
    ) {
        guard connectionStatus == .connected, let conn = connection else {
            completion(.failure(AppleTVAppRequestError.notConnected))
            return
        }
        let generation = sessionGeneration
        conn.fetchLaunchableApps { [weak self, weak conn] result in
            guard let self, self.isCurrent(conn, generation: generation) else { return }
            if case .success(let apps) = result { self.installedApps = apps }
            completion(result)
        }
    }

    /// Success means Apple TV acknowledged _launchApp; it does not confirm the
    /// app's visible foreground state. No reply within eight seconds is failure.
    /// Completion runs on main and is suppressed after this session is retired.
    public func requestAppLaunch(
        bundleID: String,
        completion: @escaping (Result<Void, Swift.Error>) -> Void
    ) {
        guard connectionStatus == .connected, let conn = connection else {
            completion(.failure(AppleTVAppRequestError.notConnected))
            return
        }
        let generation = sessionGeneration
        conn.requestAppLaunch(bundleID: bundleID) { [weak self, weak conn] result in
            guard let self, self.isCurrent(conn, generation: generation) else { return }
            completion(result)
        }
    }

    /// Update the Apple TV text field to match `newText`.
    ///
    /// Sends only the diff: appends new characters when typing forward,
    /// or clears and re-types when characters are deleted (backspace).
    public func updateRemoteText(_ newText: String) {
        guard let connection else { return }

        let ensureSession: (@escaping (Data) -> Void) -> Void = { [weak self] handler in
            if let uuid = self?.textInputSessionUUID {
                handler(uuid)
                return
            }
            connection.stopTextInput { _ in
                connection.startTextInput { response in
                    guard let content = response["_c"],
                          let tiData = content["_tiD"]?.dataValue,
                          let result = try? TextInputSession.decodeStartResponse(tiData) else {
                        log.debug("No active text field")
                        return
                    }
                    self?.textInputSessionUUID = result.sessionUUID
                    handler(result.sessionUUID)
                }
            }
        }

        ensureSession { [weak self] uuid in
            guard let self else { return }
            if newText.hasPrefix(self.sentText) {
                // Typed forward — send only the new characters
                let added = String(newText.dropFirst(self.sentText.count))
                if !added.isEmpty {
                    connection.sendTextInputEvent(added, sessionUUID: uuid)
                }
            } else {
                // Backspace or edit — atomic clear + replace in one event
                connection.replaceTextInputEvent(newText, sessionUUID: uuid)
            }
            self.sentText = newText
        }
    }

    /// Reset local text tracking (call when closing keyboard).
    public func resetTextInputState() {
        sentText = ""
    }

    private func applyTouchTranslation(_ translation: CGPoint) {
        let pointDelta = CGPoint(
            x: translation.x - touchLastTranslation.x,
            y: translation.y - touchLastTranslation.y
        )
        guard pointDelta != .zero else { return }

        touchLastTranslation = translation
        applyVirtualDelta(TouchMotionProfile.virtualDelta(for: pointDelta, referenceSize: touchReferenceSize))
    }

    private func applyNormalizedTouchTranslation(dx: CGFloat, dy: CGFloat) {
        let deltaDx = Double(dx - touchLastNormalizedDx) * TouchMotionProfile.center
        let deltaDy = Double(dy - touchLastNormalizedDy) * TouchMotionProfile.center
        guard deltaDx != 0 || deltaDy != 0 else { return }

        touchLastNormalizedDx = dx
        touchLastNormalizedDy = dy
        applyVirtualDelta(CGPoint(x: CGFloat(deltaDx), y: CGFloat(deltaDy)))
    }

    private func applyVirtualDelta(_ virtualDelta: CGPoint) {
        guard touchIsActive else { return }

        var remainingX = Double(virtualDelta.x)
        var remainingY = Double(virtualDelta.y)

        while abs(remainingX) > .ulpOfOne || abs(remainingY) > .ulpOfOne {
            let targetX = touchVirtualX + remainingX
            let targetY = touchVirtualY + remainingY

            if isWithinTouchBounds(x: targetX, y: targetY) {
                touchVirtualX = targetX
                touchVirtualY = targetY
                connection?.sendTouchEvent(
                    x: Int64(touchVirtualX.rounded()),
                    y: Int64(touchVirtualY.rounded()),
                    phase: .hold
                )
                return
            }

            let fraction = min(
                fractionToBoundary(current: touchVirtualX, delta: remainingX),
                fractionToBoundary(current: touchVirtualY, delta: remainingY)
            )
            let clampedFraction = Swift.max(0, Swift.min(1, fraction))

            touchVirtualX = clampTouchCoordinate(touchVirtualX + remainingX * clampedFraction)
            touchVirtualY = clampTouchCoordinate(touchVirtualY + remainingY * clampedFraction)
            connection?.sendTouchEvent(
                x: Int64(touchVirtualX.rounded()),
                y: Int64(touchVirtualY.rounded()),
                phase: .release
            )

            remainingX *= 1 - clampedFraction
            remainingY *= 1 - clampedFraction
            touchVirtualX = TouchMotionProfile.center
            touchVirtualY = TouchMotionProfile.center
            connection?.sendTouchEvent(
                x: Int64(TouchMotionProfile.center),
                y: Int64(TouchMotionProfile.center),
                phase: .press
            )
        }
    }

    private func continueTouchInertia(with deltas: [CGPoint], index: Int, sequenceID: UInt64) {
        guard index < deltas.count else {
            finishTouch()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + TouchMotionProfile.sampleInterval) { [weak self] in
            guard let self else { return }
            guard self.touchIsActive, self.touchSequenceID == sequenceID else { return }

            self.applyVirtualDelta(deltas[index])
            self.continueTouchInertia(with: deltas, index: index + 1, sequenceID: sequenceID)
        }
    }

    private func finishTouch() {
        guard touchIsActive else { return }

        connection?.sendTouchEvent(
            x: Int64(touchVirtualX.rounded()),
            y: Int64(touchVirtualY.rounded()),
            phase: .release
        )
        touchIsActive = false
    }

    private func isWithinTouchBounds(x: Double, y: Double) -> Bool {
        (0...TouchMotionProfile.touchpadSize).contains(x) &&
        (0...TouchMotionProfile.touchpadSize).contains(y)
    }

    private func fractionToBoundary(current: Double, delta: Double) -> Double {
        guard delta != 0 else { return .infinity }
        if delta > 0 {
            return (TouchMotionProfile.touchpadSize - current) / delta
        }
        return -current / delta
    }

    private func clampTouchCoordinate(_ value: Double) -> Double {
        Swift.max(0, Swift.min(TouchMotionProfile.touchpadSize, value))
    }

    // MARK: - Frame handling

    private var pendingM2: CompanionFrame?
    private var pendingPairVerify: PairVerify?

    private func handleFrame(_ frame: CompanionFrame) {
        log.debug("Frame received: type=\(String(describing: frame.type)) payload=\(frame.payload.count) bytes")
        switch frame.type {
        case .pairSetupNext:
            handlePairSetupResponse(frame)
        case .pairVerifyNext:
            handlePairVerifyResponse(frame)
        case .opackEncrypted, .opackUnencrypted:
            handleOPACKMessage(frame)
        default:
            break
        }
    }

    private func handlePairSetupResponse(_ frame: CompanionFrame) {
        guard let pairSetup else { return }

        // Determine which step based on TLV seqNo
        let opack: OPACK.Value
        do {
            opack = try OPACK.unpack(frame.payload)
        } catch {
            log.error("Failed to unpack pair-setup response: \(error.localizedDescription)")
            return
        }
        guard let pd = opack["_pd"]?.dataValue else { return }
        let tlv = TLV8.decode(pd)
        guard let seqData = TLV8.find(.seqNo, in: tlv), let seq = seqData.first else { return }

        if let errorData = TLV8.find(.error, in: tlv), let code = errorData.first {
            connectionStatus = .error(PairSetup.Error.serverError(code).localizedDescription)
            return
        }

        switch seq {
        case 0x02: // M2: got salt + server public key, need PIN
            guard TLV8.find(.salt, in: tlv) != nil, TLV8.find(.publicKey, in: tlv) != nil else {
                connectionStatus = .error("Invalid pairing challenge from Apple TV")
                return
            }
            pendingM2 = frame
            connectionStatus = .pairing

        case 0x04: // M4: got server proof, send M5
            do {
                let (m5Frame, partialCreds) = try pairSetup.verifyAndExchangeIdentity(m4Frame: frame)
                self.partialCredentials = partialCreds
                connection?.send(frame: m5Frame)
            } catch {
                log.error("Pair-setup M4/M5 failed: \(error.localizedDescription)")
                self.connectionStatus = .error(error.localizedDescription)
            }

        case 0x06: // M6: got server identity, pairing complete
            do {
                guard let partial = partialCredentials else { return }
                let credentials = try pairSetup.processServerIdentity(m6Frame: frame, partialCredentials: partial)
                log.info("Pair-setup complete — serverID: \(credentials.serverID)")

                if let deviceID = connectedDeviceID {
                    do {
                        try KeychainStorage.save(credentials: credentials, for: deviceID)
                    } catch {
                        connectionStatus = .error("Could not save pairing credentials: \(error.localizedDescription)")
                        return
                    }
                }

                self.currentCredentials = credentials
                self.pairSetup = nil
                self.partialCredentials = nil
                self.pendingM2 = nil
                startPairVerify(credentials: credentials)
            } catch {
                log.error("Pair-setup M6 failed: \(error.localizedDescription)")
                self.connectionStatus = .error(error.localizedDescription)
            }

        default:
            break
        }
    }

    private func startPairVerify(credentials: HAPCredentials) {
        guard let connection else { return }
        let verify = PairVerify(credentials: credentials)
        self.pendingPairVerify = verify
        let m1 = verify.startVerify()
        connection.send(frame: m1)
    }

    private func handlePairVerifyResponse(_ frame: CompanionFrame) {
        guard let verify = pendingPairVerify else { return }

        let opack: OPACK.Value
        do {
            opack = try OPACK.unpack(frame.payload)
        } catch {
            log.error("Failed to unpack pair-verify response: \(error.localizedDescription)")
            return
        }
        guard let pd = opack["_pd"]?.dataValue else { return }
        let tlv = TLV8.decode(pd)
        guard let seqData = TLV8.find(.seqNo, in: tlv), let seq = seqData.first else { return }

        if let errorData = TLV8.find(.error, in: tlv), let code = errorData.first {
            connectionStatus = .error(PairSetup.Error.serverError(code).localizedDescription)
            return
        }

        switch seq {
        case 0x02: // M2: got server ephemeral + encrypted proof
            do {
                let m3Frame = try verify.processAndProve(m2Frame: frame)
                connection?.send(frame: m3Frame)
            } catch {
                log.error("Pair-verify M2 failed: \(error.localizedDescription)")

                // Identity mismatch means the Apple TV was factory-reset or replaced.
                // Delete stale credentials and start fresh pairing automatically.
                if let device = connectedDevice, case .identityMismatch = error as? PairVerify.Error {
                    log.info("Identity mismatch for \(device.id) — deleting stale credentials and re-pairing")
                    KeychainStorage.delete(for: device.id)
                    currentCredentials = nil
                    connection?.disconnect()
                    connection = nil
                    connect(to: device)
                    return
                }

                let message: String
                if error is CryptoKit.CryptoKitError {
                    message = "Pairing credentials are invalid — try unpairing and pairing again"
                } else {
                    message = error.localizedDescription
                }
                isReconnecting = false
                connectionStatus = .error(message)
            }

        case 0x04: // M4: verify complete, enable encryption
            if let crypto = verify.deriveTransportKeys() {
                connection?.enableEncryption(crypto)
                pendingPairVerify = nil
                log.info("Pair-verify complete, encrypted session established")
                self.startSession()
            } else {
                log.error("Failed to derive transport keys")
                self.connectionStatus = .error("Failed to derive session keys")
            }

        default:
            break
        }
    }

    private func startSession() {
        fetchOSVersion()
        startCompanionSession()
        if enableMediaRemote { startMRPViaTunnel() }
    }

    /// Fire-and-forget `_systemInfo` to read the device's `_osV`. We don't
    /// gate session start on this — the version is informational only, used
    /// by the UI to surface a tvOS-26.5-beta-specific empty state.
    private func fetchOSVersion() {
        guard let credentials = currentCredentials else { return }
        connection?.sendSystemInfo(
            clientID: credentials.clientID,
            clientPublicKey: credentials.clientLTPK,
            deviceModel: Self.hardwareModel
        ) { [weak self] response in
            guard let osV = response["_c"]?["_osV"]?.stringValue else { return }
            log.info("Apple TV osVersion=\(osV)")
            self?.osVersion = osV
        }
    }

    /// iPhone hardware identifier (e.g. "iPhone17,1"). Sent in `_systemInfo`
    /// as the `model` field; tvOS uses it for client-side display only.
    private static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "iPhone17,1" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }

    private func isCurrent(_ connection: CompanionConnection?, generation: UInt64) -> Bool {
        guard let connection else { return false }
        return sessionGeneration == generation && self.connection === connection
    }

    private func installCompanionCallbacks(_ conn: CompanionConnection, generation: UInt64) {
        conn.onFrame = { [weak self, weak conn] frame in
            guard let self, self.isCurrent(conn, generation: generation) else { return }
            self.handleFrame(frame)
        }
        conn.onDisconnect = { [weak self, weak conn] error in
            guard let self, self.isCurrent(conn, generation: generation) else { return }
            let canReconnect = self.currentCredentials != nil &&
                (self.connectionStatus == .connected || self.isReconnecting)
            self.connection = nil
            self.textInputSessionUUID = nil
            self.sentText = ""
            if canReconnect && self.companionRetryCount < Self.maxCompanionRetries {
                self.companionRetryCount += 1
                self.connectionStatus = .connecting
                self.isReconnecting = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    self.reconnectCompanion()
                }
            } else {
                self.isReconnecting = false
                self.connectionStatus = .error(error?.localizedDescription ?? "Disconnected from Apple TV")
            }
        }
    }

    private func startCompanionSession() {
        guard let conn = connection else { return }
        let generation = sessionGeneration
        conn.startSession { [weak self, weak conn] sid in
            guard let self, let conn, self.isCurrent(conn, generation: generation) else { return }
            guard let sid else {
                self.connectionStatus = .error("Apple TV did not start a remote session")
                return
            }
            log.info("Session ready, SID=0x\(String(sid, radix: 16))")
            conn.startKeepAlive()
            if self.enableMediaRemote {
                conn.startTouchSession()
                conn.startTextInput { [weak self, weak conn] response in
                    guard let self, self.isCurrent(conn, generation: generation) else { return }
                    if let content = response["_c"],
                       let tiData = content["_tiD"]?.dataValue,
                       let result = try? TextInputSession.decodeStartResponse(tiData) {
                        self.textInputSessionUUID = result.sessionUUID
                    }
                }
            }
            // Newer tvOS versions expect TVRC registration. Older versions may
            // ignore it, so proceed after two seconds only for this live session.
            var didProceed = false
            let proceed: () -> Void = { [weak self, weak conn] in
                guard let self, self.isCurrent(conn, generation: generation), !didProceed else { return }
                didProceed = true
                self.isReconnecting = false
                self.companionRetryCount = 0
                self.connectionStatus = .connected
                self.discovery.pause()
                self.isScanning = false
                self.flushPendingCompanionCommands()
                if self.enableMediaRemote { self.fetchApps() }
            }
            conn.startTVRCSession { proceed() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: proceed)
        }
    }

    private func reconnectCompanion() {
        guard let device = connectedDevice, let credentials = currentCredentials else {
            connectionStatus = .error("Cannot reconnect without a paired Apple TV")
            return
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        connection?.disconnect()
        pendingPairVerify = nil
        isReconnecting = true
        connectionStatus = .connecting
        let conn = CompanionConnection()
        self.connection = conn
        installCompanionCallbacks(conn, generation: generation)
        conn.onConnect = { [weak self, weak conn] in
            guard let self, self.isCurrent(conn, generation: generation) else { return }
            self.startPairVerify(credentials: credentials)
        }
        conn.connectToService(name: device.name)
    }

    private func performOrQueueCompanionCommand(_ command: @escaping () -> Void) {
        if connectionStatus == .connected, connection != nil {
            command()
            return
        }

        pendingCompanionCommands.append(command)
        guard ensureCompanionConnectionForPendingCommands() else {
            log.warning("Dropping queued command: no saved device available")
            pendingCompanionCommands.removeAll()
            return
        }
    }

    private func ensureCompanionConnectionForPendingCommands() -> Bool {
        if connectionStatus == .connected, connection != nil {
            return true
        }
        if connectionStatus == .connecting || connectionStatus == .pairing {
            return true
        }

        guard let device = connectedDevice ?? LastConnectedDeviceStorage.load() else {
            return false
        }

        connect(to: device, preservingPendingCommands: true)
        return true
    }

    private func flushPendingCompanionCommands() {
        guard !pendingCompanionCommands.isEmpty else { return }

        let commands = pendingCompanionCommands
        pendingCompanionCommands.removeAll()
        for command in commands {
            command()
        }
    }

    private func startMRPViaTunnel() {
        guard enableMediaRemote, !mrpManager.isConnected else { return }
        let generation = sessionGeneration
        guard let device = connectedDevice, !device.host.isEmpty, let creds = currentCredentials else {
            log.warning("Cannot start MRP: no device host or credentials")
            return
        }

        // AirPlay runs on port 7000 on the same host as companion-link
        let airplayPort: UInt16 = 7000
        let attempt = mrpRetryCount + 1
        log.info("Starting MRP via AirPlay tunnel: \(device.host):\(airplayPort) (attempt \(attempt))")
        mrpManager.onDisconnect = { [weak self] error in
            guard let self, self.sessionGeneration == generation else { return }
            if self.connectionStatus == .connected {
                if self.mrpRetryCount < Self.maxMRPRetries {
                    self.mrpRetryCount += 1
                    log.info("MRP tunnel lost — retrying (\(self.mrpRetryCount)/\(Self.maxMRPRetries))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.sessionGeneration == generation else { return }
                        self.startMRPViaTunnel()
                    }
                } else {
                    log.info("MRP tunnel lost — max retries reached, disconnecting")
                    self.mrpRetryCount = 0
                    self.connectionStatus = .disconnected
                    self.connectedDeviceName = nil
                    self.connectedDevice = nil
                }
            }
        }
        mrpManager.onReady = { [weak self] in
            self?.mrpRetryCount = 0
        }
        mrpManager.onKeyboardFocusChange = { [weak self] focused in
            DispatchQueue.main.async {
                self?.keyboardFocused = focused
            }
        }
        mrpManager.connect(host: device.host, port: airplayPort, credentials: creds)
    }

    public func fetchApps() {
        fetchLaunchableApps { result in
            if case .failure(let error) = result {
                log.warning("App listing failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - App ordering

    public var orderedGridItems: [AppGridItem] {
        let saved = connectedDeviceID.flatMap { AppOrderStorage.load(deviceID: $0) }
        return AppOrderStorage.applyOrder(
            savedItems: saved,
            apps: installedApps,
            builtInBundleIDs: BuiltInApps.bundleIDs
        )
    }

    /// Legacy flat ordering (for callers not yet migrated).
    public var orderedApps: [(bundleID: String, name: String)] {
        let savedOrder = connectedDeviceID.flatMap { AppOrderStorage.loadFlat(deviceID: $0) }
        return AppOrderStorage.applyOrder(
            savedOrder: savedOrder,
            apps: installedApps,
            builtInBundleIDs: BuiltInApps.bundleIDs
        )
    }

    public func saveGridItems(_ items: [AppGridItem]) {
        guard let deviceID = connectedDeviceID else { return }
        AppOrderStorage.save(deviceID: deviceID, items: AppOrderStorage.toDTO(items))
    }

    public func saveAppOrder(_ bundleIDs: [String]) {
        guard let deviceID = connectedDeviceID else { return }
        AppOrderStorage.save(deviceID: deviceID, order: bundleIDs)
    }


    private func handleOPACKMessage(_ frame: CompanionFrame) {
        let message: OPACK.Value
        do {
            message = try OPACK.unpack(frame.payload)
        } catch {
            log.warning("Failed to unpack OPACK payload (\(frame.payload.count) bytes): \(error.localizedDescription)")
            return
        }
        let type = message["_t"]?.intValue
        let keys = message.dictValue?.map { String(describing: $0.key) } ?? []
        log.debug("OPACK message: _t=\(type ?? -1) keys=\(keys)")

        switch type {
        case CompanionMessageType.event.rawValue:
            let eventName = message["_i"]?.stringValue
            log.debug("Event: \(eventName ?? "?")")

        case CompanionMessageType.response.rawValue:
            let xid = message["_x"]?.intValue ?? -1
            connection?.dispatchResponse(xid: xid, message: message)

        default:
            log.debug("Unhandled OPACK message type: \(type ?? -1)")
        }
    }
}
