import AppKit
import RemoteKit
import SwiftUI

private typealias AppsViewState<Value> = SwiftUI.State<Value>

struct AppsView: View {
    @Bindable var model: RemoteModel
    @AppsViewState private var search = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 3)

    private var filteredApps: [RemoteApp] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.apps : model.apps.filter { $0.name.localizedStandardContains(query) }
    }

    private var isLoading: Bool {
        if case .loading = model.appsState { return true }
        return false
    }

    private var canLaunch: Bool {
        guard model.canSend, model.launchingAppID == nil else { return false }
        if case .loaded = model.appsState { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Search apps", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .accessibilityLabel("Search apps")
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear app search")
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))

                Button { model.loadApps(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(isLoading || model.launchingAppID != nil)
                .help("Refresh installed apps")
                .accessibilityLabel("Refresh installed apps")
            }

            if let message = model.appLaunchError {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.apps.isEmpty {
                emptyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if case .failed(let message) = model.appsState {
                    HStack(alignment: .top, spacing: 7) {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Retry") { model.loadApps(force: true) }
                            .font(.system(size: 11))
                            .buttonStyle(.borderless)
                    }
                }

                if filteredApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No matching apps")
                            .font(.callout.weight(.medium))
                        Button("Clear Search") { search = "" }
                            .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                            ForEach(filteredApps, id: \.id) { app in
                                appButton(app)
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 2)
                    }
                    .scrollIndicators(.visible)
                }
            }

            HStack(spacing: 6) {
                if isLoading {
                    ProgressView().controlSize(.mini)
                    Text(model.apps.isEmpty ? "Loading apps…" : "Refreshing apps…")
                } else if let id = model.launchingAppID,
                          let app = model.apps.first(where: { $0.id == id }) {
                    ProgressView().controlSize(.mini)
                    Text("Opening \(app.name)…").lineLimit(1)
                } else {
                    Text("\(model.apps.count) \(model.apps.count == 1 ? "app" : "apps")")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(height: 15)
        }
        .frame(height: 328)
        .task { model.loadApps() }
        .onChange(of: model.selectedDeviceID) { _, _ in search = "" }
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch model.appsState {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Getting apps from your TV…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Couldn't load apps")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.loadApps(force: true) }
            }
            .padding(.horizontal, 8)
        case .loaded:
            VStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No apps found")
                    .font(.headline)
                Text("Refresh to load your Apple TV's apps again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Refresh Apps") { model.loadApps(force: true) }
            }
            .padding(.horizontal, 8)
        }
    }

    private func appButton(_ app: RemoteApp) -> some View {
        Button { model.launchApp(id: app.id) } label: {
            VStack(spacing: 7) {
                AppIconView(bundleID: app.id)
                    .overlay {
                        if model.launchingAppID == app.id {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.regularMaterial)
                            ProgressView().controlSize(.small)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if model.lastLaunchedAppID == app.id, model.launchingAppID == nil {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 17))
                                .background(.background, in: Circle())
                                .offset(x: 4, y: 4)
                                .accessibilityLabel("Launch requested")
                        }
                    }
                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28, alignment: .top)
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(AppTileStyle())
        .disabled(!canLaunch)
        .accessibilityLabel("Open \(app.name)")
        .accessibilityValue(model.launchingAppID == app.id ? "Opening" :
            model.lastLaunchedAppID == app.id ? "Launch requested" : "")
        .help("Open \(app.name) on \(model.selectedDeviceName)")
    }
}

private struct AppIconView: View {
    let bundleID: String
    private let icons = AppIconStore.shared

    var body: some View {
        Group {
            if let image = icons.images[bundleID] {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        Image(systemName: AppIconStore.builtInSymbol(for: bundleID) ?? "app.dashed")
                            .font(.system(size: 25, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: bundleID) { await icons.load(bundleID: bundleID) }
    }
}

private struct AppTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyle.Configuration
        @AppsViewState private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background(
                    Color.accentColor.opacity(isEnabled && (isHovered || configuration.isPressed) ? 0.1 : 0),
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }
    }
}
