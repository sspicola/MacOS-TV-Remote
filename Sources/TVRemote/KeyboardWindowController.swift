import AppKit
import Observation
import RemoteKit
import SwiftUI

@MainActor
final class KeyboardWindowController: NSObject, NSWindowDelegate {
    private let model: RemoteModel
    private var panel: NSPanel?
    private var displayedSession: Data?
    private var lastFocusRequest: UInt64 = 0

    init(model: RemoteModel) {
        self.model = model
        super.init()
        observe()
    }

    private func observe() {
        let (presented, sessionID, name, focusRequest) = withObservationTracking {
            (model.isKeyboardPresented, model.textInput?.id, model.selectedDeviceName, model.keyboardFocusRequest)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        let requestedFocus = focusRequest != lastFocusRequest
        lastFocusRequest = focusRequest
        guard presented, let sessionID else {
            panel?.orderOut(nil)
            panel?.contentViewController = nil
            panel = nil
            displayedSession = nil
            return
        }
        if panel == nil || displayedSession != sessionID {
            panel?.orderOut(nil)
            let window = NSPanel(contentRect: .zero,
                                 styleMask: [.titled, .closable, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: KeyboardView(model: model))
            window.center()
            panel = window
            displayedSession = sessionID
        }
        panel?.title = "Type on \(name)"
        // Show the prompt without taking the keyboard away from another Mac app.
        if requestedFocus { NSApp.activate(ignoringOtherApps: true) }
        if requestedFocus || NSApp.isActive {
            panel?.makeKeyAndOrderFront(nil)
            panel?.makeFirstResponder(panel?.initialFirstResponder)
        }
        else { panel?.orderFrontRegardless() }
    }

    func windowWillClose(_ notification: Notification) {
        model.dismissKeyboard()
    }
}

private struct KeyboardView: View {
    let model: RemoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Apple TV Keyboard", systemImage: "keyboard")
                .font(.headline)
            Text("Type or paste here. Your text appears on the TV as you type.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            KeyboardTextField(text: model.keyboardText, onChange: model.editKeyboardText,
                              onDone: model.dismissKeyboard)
                .frame(height: 28)

            if let error = model.keyboardError {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("Try Again") { model.flushKeyboardInput() }
                        .controlSize(.small)
                }
            }
            HStack {
                Text(model.isDemo ? "Preview · text is simulated" : model.selectedDeviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.isSendingText { ProgressView().controlSize(.small) }
                Button("Done") { model.dismissKeyboard() }
                    .help("Close this window. Use the remote to submit on the TV.")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Wait for composed input to be committed before sending it to the TV.
private struct KeyboardTextField: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = InputField()
        field.placeholderString = "Type on Apple TV"
        field.setAccessibilityLabel("Text for Apple TV")
        field.font = .systemFont(ofSize: 16)
        field.isEditable = true
        field.isSelectable = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != text { field.stringValue = text }
    }

    final class InputField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.isKeyWindow else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: KeyboardTextField
        init(parent: KeyboardTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onChange(control.stringValue)
                parent.onDone()
                return true
            }
            return false
        }
    }
}
