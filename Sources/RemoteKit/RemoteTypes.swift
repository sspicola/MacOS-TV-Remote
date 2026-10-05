import Foundation

public struct RemoteDevice: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    public let host: String
    public let port: UInt16

    public init(id: String, name: String, host: String = "", port: UInt16 = 0) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }
}

public enum RemotePhase: Equatable, Sendable {
    case idle, connecting, pairing, verifying, connected
    case failed(String)
}

public struct RemoteApp: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum RemoteScreen: String, CaseIterable, Sendable {
    case remote, apps
}

public enum AppListState: Equatable, Sendable {
    case idle, loading, loaded
    case failed(String)
}

public enum RemoteCommand: String, CaseIterable, Sendable {
    case up, down, left, right, select, back, home, playPause, volumeDown, volumeUp

    public var label: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .select: "Select"
        case .back: "Back"
        case .home: "Home"
        case .playPause: "Play / pause"
        case .volumeDown: "Volume down"
        case .volumeUp: "Volume up"
        }
    }
}

@MainActor
public protocol RemoteTransport: AnyObject {
    var onDevicesChanged: (([RemoteDevice]) -> Void)? { get set }
    var onPhaseChanged: ((RemotePhase) -> Void)? { get set }
    func startScanning()
    func refreshScanning()
    func stopScanning()
    func connect(to device: RemoteDevice)
    func submitPIN(_ pin: String)
    func disconnect()
    func send(_ command: RemoteCommand)
    func fetchApps(completion: @escaping (Result<[RemoteApp], Error>) -> Void)
    func launchApp(bundleID: String, completion: @escaping (Result<Void, Error>) -> Void)
}
