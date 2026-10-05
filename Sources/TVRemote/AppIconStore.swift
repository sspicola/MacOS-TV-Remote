import AppKit
import Foundation
import Observation

/// App Store artwork matched by bundle identifier and cached independently of the UI.
@MainActor @Observable
final class AppIconStore {
    static let shared = AppIconStore()
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var requests: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 8_000_000, diskCapacity: 30_000_000)
        session = URLSession(configuration: configuration)
    }

    static func builtInSymbol(for bundleID: String) -> String? {
        [
            "com.apple.TVAppStore": "bag",
            "com.apple.Arcade": "gamecontroller.fill",
            "com.apple.TVHomeSharing": "rectangle.inset.filled.on.rectangle",
            "com.apple.TVMovies": "film",
            "com.apple.TVMusic": "music.note",
            "com.apple.TVPhotos": "photo.fill",
            "com.apple.TVSearch": "magnifyingglass",
            "com.apple.TVSettings": "gearshape.fill",
            "com.apple.TVWatchList": "tv.fill",
            "com.apple.TVShows": "tv",
            "com.apple.Sing": "music.mic",
            "com.apple.facetime": "video.fill",
            "com.apple.Fitness": "figure.run",
            "com.apple.podcasts": "antenna.radiowaves.left.and.right"
        ][bundleID]
    }

    func load(bundleID: String) async {
        guard Self.builtInSymbol(for: bundleID) == nil,
              images[bundleID] == nil else { return }
        if let date = retryAfter[bundleID], date > Date() { return }
        if let request = requests[bundleID] {
            await request.value
            return
        }

        // Closing or filtering the Apps view must not cancel a shared icon request.
        let request = Task { [weak self] in
            guard let self else { return }
            await self.fetch(bundleID: bundleID)
            self.requests[bundleID] = nil
        }
        requests[bundleID] = request
        await request.value
    }

    private func fetch(bundleID: String) async {
        retryAfter[bundleID] = nil

        let country = Locale.current.region?.identifier.lowercased() ?? "us"
        for entity in ["tvSoftware", "software"] {
            if Task.isCancelled { return }
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                URLQueryItem(name: "bundleId", value: bundleID),
                URLQueryItem(name: "entity", value: entity),
                URLQueryItem(name: "country", value: country)
            ]
            guard let url = components.url else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let result = try? JSONDecoder().decode(LookupResponse.self, from: data),
                      let app = result.results.first(where: { $0.bundleId == bundleID }),
                      let iconURL = URL(string: app.artworkUrl100 ?? app.artworkUrl512 ?? ""),
                      iconURL.scheme == "https" else { continue }
                let (artwork, imageResponse) = try await session.data(from: iconURL)
                guard (imageResponse as? HTTPURLResponse)?.statusCode == 200,
                      artwork.count < 5_000_000,
                      let image = NSImage(data: artwork) else { continue }
                if Task.isCancelled { return }
                images[bundleID] = image
                return
            } catch {
                if Task.isCancelled { return }
            }
        }
        retryAfter[bundleID] = Date().addingTimeInterval(60)
    }

    private struct LookupResponse: Decodable {
        let results: [LookupApp]
    }

    private struct LookupApp: Decodable {
        let bundleId: String?
        let artworkUrl100: String?
        let artworkUrl512: String?
    }
}
