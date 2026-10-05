import Foundation

/// Failures from Companion app enumeration or acknowledged launch requests.
public enum AppleTVAppRequestError: Swift.Error, LocalizedError, Equatable {
    case notConnected
    case connectionClosed
    case timedOut(operation: String)
    case malformedResponse
    case rejected(message: String)
    case unsupported(message: String)
    case invalidBundleIdentifier

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect to an Apple TV before using apps."
        case .connectionClosed:
            return "The connection to Apple TV closed before it replied."
        case .timedOut(let operation):
            return operation == "_launchApp"
                ? "Apple TV did not confirm the launch. Check the TV before trying again."
                : "Apple TV did not reply with its apps. Try again."
        case .malformedResponse:
            return "Apple TV returned an unreadable response."
        case .rejected(let message), .unsupported(let message):
            return message
        case .invalidBundleIdentifier:
            return "The app identifier is missing."
        }
    }
}

/// Pure response validation shared by enumeration and launch requests.
/// Companion reports request failures through top-level _em / _ec fields.
enum CompanionAppResponse {
    static func validateAcknowledgment(_ response: OPACK.Value) throws {
        guard response.dictValue != nil,
              response["_t"]?.intValue == CompanionMessageType.response.rawValue else {
            throw AppleTVAppRequestError.malformedResponse
        }
        if let errorMessage = response["_em"] {
            guard let message = errorMessage.stringValue else {
                throw AppleTVAppRequestError.malformedResponse
            }
            let readable = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = readable.isEmpty ? "Apple TV rejected the apps request." : readable
            let normalized = detail.lowercased()
            if normalized.contains("unsupported") || normalized.contains("not supported") ||
                normalized.contains("unknown command") || normalized.contains("unrecognized command") {
                throw AppleTVAppRequestError.unsupported(message: detail)
            }
            throw AppleTVAppRequestError.rejected(message: detail)
        }
        if let errorCode = response["_ec"] {
            guard let code = errorCode.intValue else {
                throw AppleTVAppRequestError.malformedResponse
            }
            if code != 0 {
                throw AppleTVAppRequestError.rejected(message: "Apple TV rejected the apps request (code \(code)).")
            }
        }
    }

    static func appList(_ response: OPACK.Value) throws -> [(bundleID: String, name: String)] {
        try validateAcknowledgment(response)
        guard let entries = response["_c"]?.dictValue else {
            throw AppleTVAppRequestError.malformedResponse
        }
        var apps: [(bundleID: String, name: String)] = []
        var identifiers = Set<String>()
        for entry in entries {
            guard let bundleID = entry.key.stringValue,
                  let name = entry.value.stringValue,
                  !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  identifiers.insert(bundleID).inserted else {
                throw AppleTVAppRequestError.malformedResponse
            }
            apps.append((bundleID: bundleID, name: name))
        }
        return apps.sorted { left, right in
            let order = left.name.localizedCaseInsensitiveCompare(right.name)
            return order == .orderedSame ? left.bundleID < right.bundleID : order == .orderedAscending
        }
    }
}

extension CompanionConnection {
    func fetchLaunchableApps(
        completion: @escaping (Result<[(bundleID: String, name: String)], Swift.Error>) -> Void
    ) {
        sendRequestAwaitingResponse(eventName: "FetchLaunchableApplicationsEvent", content: .dict([])) { result in
            completion(result.flatMap { response in Result { try CompanionAppResponse.appList(response) } })
        }
    }

    func requestAppLaunch(
        bundleID: String,
        completion: @escaping (Result<Void, Swift.Error>) -> Void
    ) {
        let identifier = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            completion(.failure(AppleTVAppRequestError.invalidBundleIdentifier))
            return
        }
        sendRequestAwaitingResponse(
            eventName: "_launchApp", content: .dictionary([("_bundleID", .string(identifier))])
        ) { result in
            completion(result.flatMap { response in Result { try CompanionAppResponse.validateAcknowledgment(response) } })
        }
    }
}
