import Foundation

public struct AppleTVTextInput: Equatable, Sendable {
    public let id: Data
    public let text: String
}

public enum AppleTVTextInputError: LocalizedError {
    case fieldClosed, timedOut

    public var errorDescription: String? {
        switch self {
        case .fieldClosed: return "This Apple TV text field is no longer active."
        case .timedOut: return "Sending text to Apple TV timed out."
        }
    }
}

struct CompanionKeyboardState {
    private(set) var session: AppleTVTextInput?
    private(set) var revision: UInt64 = 0

    mutating func reset() {
        revision &+= 1
        session = nil
    }

    mutating func receive(event: String, content: OPACK.Value?) {
        switch event {
        case "_tiStarted":
            revision &+= 1
            session = Self.decode(content)
        case "_tiStopped": reset()
        default: break
        }
    }

    mutating func receiveInitial(_ content: OPACK.Value?, revision expected: UInt64) {
        // Focus events can arrive before the reply to our initial subscription.
        guard revision == expected else { return }
        session = Self.decode(content)
    }

    private static func decode(_ content: OPACK.Value?) -> AppleTVTextInput? {
        guard let data = content?["_tiD"]?.dataValue,
              let decoded = try? TextInputSession.decodeStartResponse(data) else { return nil }
        return AppleTVTextInput(id: decoded.sessionUUID, text: decoded.currentText)
    }
}
