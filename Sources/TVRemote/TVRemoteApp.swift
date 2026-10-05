import AppKit
import RemoteKit
import SwiftUI

@main
struct TVRemoteApp: App {
    @NSApplicationDelegateAdaptor(RemoteAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("TV Remote", systemImage: "appletv") {
            RemoteView(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class RemoteAppDelegate: NSObject, NSApplicationDelegate {
    let model: RemoteModel
    private var workspaceObservers: [NSObjectProtocol] = []
    private var previewWindow: NSWindow?

    override init() {
        let isDemo = CommandLine.arguments.contains("--demo")
        model = RemoteModel(transport: isDemo ? DemoTransport() : CompanionTransport(), isDemo: isDemo)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.prepareForSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.resumeAfterWake() }
        })

        if model.isDemo {
            model.selectDevice(id: "demo-living")
        }
        if CommandLine.arguments.contains("--preview-window") {
            let content = NSHostingController(rootView: RemoteView(model: model))
            let window = NSWindow(contentViewController: content)
            window.title = model.isDemo ? "TV Remote Preview" : "TV Remote"
            window.styleMask = [.titled, .closable]
            window.level = .floating
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            previewWindow = window
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}
