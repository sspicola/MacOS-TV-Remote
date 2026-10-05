import AppKit
import RemoteKit
import SwiftUI

/// The compact remote presented by the menu bar item.
struct RemoteView: View {
    @Bindable var model: RemoteModel

    var body: some View {
        VStack(spacing: 18) {
            deviceHeader

            Picker("Screen", selection: Binding(
                get: { model.screen },
                set: { model.showScreen($0) }
            )) {
                Text("Remote").tag(RemoteScreen.remote)
                Text("Apps").tag(RemoteScreen.apps)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Remote or apps")

            if model.isDemo {
                Text("Preview · controls are simulated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch model.phase {
            case .pairing, .verifying:
                PairingView(model: model)
            default:
                if model.devices.isEmpty {
                    discoveryView
                } else {
                    connectionNotice
                    if model.canSend, model.screen == .apps {
                        AppsView(model: model)
                    } else {
                        remoteControls
                    }
                }
            }

            footer
        }
        .padding(18)
        .frame(width: 344)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.start() }
    }

    private var deviceHeader: some View {
        HStack(spacing: 11) {
            Image(systemName: "appletv")
                .font(.system(size: 25, weight: .regular))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Apple TV")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Menu {
                    ForEach(model.devices, id: \.id) { device in
                        Button {
                            model.selectDevice(id: device.id)
                        } label: {
                            Label(
                                device.name,
                                systemImage: model.selectedDeviceID == device.id ? "checkmark" : "appletv"
                            )
                        }
                    }
                    if !model.devices.isEmpty { Divider() }
                    Button("Find Apple TVs", systemImage: "arrow.clockwise") {
                        model.refresh()
                    }
                } label: {
                    Text(model.selectedDeviceID == nil ? "Choose a TV" : model.selectedDeviceName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Choose Apple TV")
                .accessibilityValue(model.selectedDeviceName)
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 5, height: 5)
                Text(connectionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }

    private var remoteControls: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Circle().strokeBorder(.primary.opacity(0.055), lineWidth: 1))
                    .shadow(color: .black.opacity(0.045), radius: 2, y: 1)

                directionButton("Up", symbol: "chevron.up", command: .up, key: .upArrow)
                    .offset(y: -65)
                directionButton("Left", symbol: "chevron.left", command: .left, key: .leftArrow)
                    .offset(x: -65)
                directionButton("Right", symbol: "chevron.right", command: .right, key: .rightArrow)
                    .offset(x: 65)
                directionButton("Down", symbol: "chevron.down", command: .down, key: .downArrow)
                    .offset(y: 65)

                Button { model.send(.select) } label: {
                    Text("Select")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 62, height: 62)
                }
                .buttonStyle(RemoteControlStyle(circular: true, filled: true))
                .keyboardShortcut(.return, modifiers: [])
                .help("Select · Return")
                .accessibilityLabel("Select")
            }
            .frame(width: 200, height: 200)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Directional controls")

            HStack(spacing: 8) {
                actionButton("Back", symbol: "chevron.left", command: .back)
                actionButton("Home", symbol: "house", command: .home)
                actionButton("Play / pause", symbol: "playpause.fill", command: .playPause)
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Play or pause · Space")
            }

            HStack(spacing: 8) {
                volumeButton("Volume down", symbol: "minus", command: .volumeDown)
                Label("Volume", systemImage: "speaker.wave.2")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
                volumeButton("Volume up", symbol: "plus", command: .volumeUp)
            }
        }
        .disabled(!model.canSend)
        .opacity(model.canSend ? 1 : 0.48)
    }

    private func directionButton(
        _ title: String,
        symbol: String,
        command: RemoteCommand,
        key: KeyEquivalent
    ) -> some View {
        Button { model.send(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 54, height: 54)
                .contentShape(Circle())
        }
        .buttonStyle(RemoteControlStyle(circular: true, filled: false))
        .keyboardShortcut(key, modifiers: [])
        .accessibilityLabel(title)
        .help("\(title) · Arrow key")
    }

    private func actionButton(_ title: String, symbol: String, command: RemoteCommand) -> some View {
        Button { model.send(command) } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 53)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(RemoteControlStyle())
        .accessibilityLabel(title)
        .help(title)
    }

    private func volumeButton(_ title: String, symbol: String, command: RemoteCommand) -> some View {
        Button { model.send(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 51, height: 40)
        }
        .buttonStyle(RemoteControlStyle())
        .accessibilityLabel(title)
        .help(title)
    }

    @ViewBuilder
    private var connectionNotice: some View {
        switch model.phase {
        case .connecting:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Connecting to your Apple TV…")
                    .font(.caption)
                Spacer(minLength: 0)
                Button("Cancel") { model.cancelConnection() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 9) {
                Label("Couldn't connect", systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.reconnect() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        case .idle:
            Text("Choose an Apple TV above to connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var discoveryView: some View {
        VStack(spacing: 13) {
            if model.isScanning {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: "appletv")
                    .font(.system(size: 35, weight: .light))
                    .foregroundStyle(.secondary)
            }

            Text(model.isScanning ? "Looking for Apple TVs…" : "No Apple TVs found")
                .font(.headline)
            Text("Connect this Mac to the same network as your Apple TV. Allow local network access if macOS asks.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !model.isScanning {
                Button("Search Again") { model.refresh() }
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 230)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                Text(footerText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(footerText)
                Spacer(minLength: 0)
                if model.isScanning && !model.devices.isEmpty {
                    ProgressView().controlSize(.mini)
                        .help("Looking for Apple TVs")
                }
                Menu {
                    Button("Refresh Apple TVs", systemImage: "arrow.clockwise") { model.refresh() }
                    Button("Reconnect", systemImage: "link") { model.reconnect() }
                        .disabled(model.selectedDeviceID == nil)
                    Divider()
                    Button("Quit TV Remote", systemImage: "power") {
                        model.stop()
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Remote options")
            }
        }
    }

    private var footerText: String {
        if model.isDemo { return model.lastAction ?? "Preview mode" }
        if let lastAction = model.lastAction, model.canSend { return lastAction }
        if model.canSend, model.screen == .apps { return "Click an app to open it on your TV" }
        if model.canSend { return "Arrow keys to navigate · Space to play / pause" }
        return "TV Remote"
    }

    private var connectionLabel: String {
        switch model.phase {
        case .idle: return "Not connected"
        case .connecting: return "Connecting"
        case .pairing: return "Pairing"
        case .verifying: return "Verifying"
        case .connected: return model.isDemo ? "Preview" : "Connected"
        case .failed: return "Disconnected"
        }
    }

    private var connectionColor: Color {
        switch model.phase {
        case .connected: return model.isDemo ? .secondary : .green
        case .connecting, .pairing, .verifying: return .orange
        case .idle, .failed: return .secondary
        }
    }
}

private struct PairingView: View {
    @Bindable var model: RemoteModel
    @FocusState private var pinIsFocused: Bool

    private var isVerifying: Bool {
        if case .verifying = model.phase { return true }
        return false
    }

    private var hasValidPIN: Bool {
        model.pin.count == 4 && model.pin.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                Text("Pair with \(model.selectedDeviceName)")
                    .font(.headline)
                Text("Enter the four-digit code shown on your TV.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField("0000", text: $model.pin)
                .font(.system(size: 27, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 152)
                .focused($pinIsFocused)
                .disabled(isVerifying)
                .accessibilityLabel("Four-digit pairing code")
                .onChange(of: model.pin) { _, value in
                    let filtered = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(4))
                    if value != filtered { model.pin = filtered }
                }
                .onSubmit {
                    if hasValidPIN && !isVerifying { model.submitPIN() }
                }

            if isVerifying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Verifying code…").font(.callout)
                }
            } else {
                Button("Pair Apple TV") { model.submitPIN() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasValidPIN)
            }

            Button("Cancel") { model.cancelConnection() }
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .onAppear { pinIsFocused = true }
    }
}

// Avoid the State macro in command-line SDKs that lack its compiler plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

private struct RemoteControlStyle: ButtonStyle {
    var circular = false
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        RemoteControlBody(configuration: configuration, circular: circular, filled: filled)
    }

    private struct RemoteControlBody: View {
        let configuration: ButtonStyle.Configuration
        let circular: Bool
        let filled: Bool
        @ViewState private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background {
                    RoundedRectangle(cornerRadius: circular ? 100 : 10)
                        .fill(backgroundColor)
                        .overlay {
                            if filled {
                                RoundedRectangle(cornerRadius: circular ? 100 : 10)
                                    .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
                            }
                        }
                }
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { isHovered = $0 }
        }

        private var backgroundColor: Color {
            if isEnabled && configuration.isPressed { return .accentColor.opacity(0.2) }
            if isEnabled && isHovered { return .accentColor.opacity(0.10) }
            if filled {
                return Color(nsColor: circular ? .windowBackgroundColor : .controlBackgroundColor)
            }
            return .clear
        }
    }
}
