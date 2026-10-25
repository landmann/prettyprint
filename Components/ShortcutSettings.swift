import AppKit
import SwiftUI

@MainActor
final class PrettyPrintSettingsPresenter: NSObject, NSWindowDelegate {
    static let shared = PrettyPrintSettingsPresenter()
    private var window: NSWindow?
    private var keyMonitor: Any?
    private weak var parentWindow: NSWindow?

    func show(relativeTo parent: NSWindow? = nil) {
        if let window {
            parentWindow = parent
            window.level = parent?.level ?? .normal
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PrettyPrint Settings"
        window.minSize = NSSize(width: 580, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = parent?.level ?? .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: PrettyPrintShortcutSettings())
        window.center()
        self.window = window
        parentWindow = parent
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window, window.isKeyWindow,
                  NSApp.modalWindow == nil, window.attachedSheet == nil else { return event }
            let shortcuts = PrettyPrintShortcuts.shared
            if shortcuts.recording != nil {
                shortcuts.record(event)
                return nil
            }
            guard !(window.firstResponder is NSTextView), let press = PrettyPrintKeyPress(event) else { return event }
            switch shortcuts.action(for: press, in: .settings) {
            case .close: window.close(); return nil
            case .settings: return nil
            default: return event
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        PrettyPrintShortcuts.shared.stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        PrettyPrintShortcuts.shared.stopRecording()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window = nil
        if let parentWindow, parentWindow.isVisible { parentWindow.makeKeyAndOrderFront(nil) }
        parentWindow = nil
    }
}

private struct PrettyPrintShortcutSettings: View {
    @ObservedObject private var shortcuts = PrettyPrintShortcuts.shared
    private let groups = ["General", "Print queue", "Editor", "Print history", "Dialogs"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DriverFinderSettings()
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keyboard shortcuts").font(.title2.weight(.semibold))
                        Text("Click a shortcut, then press the new keys. Changes save automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group).font(.headline).padding(.bottom, 8)
                            ForEach(PrettyPrintShortcutAction.allCases.filter { $0.group == group }) { action in
                                shortcutRow(action)
                            }
                        }
                    }
                    heldModifiers
                }
                .padding(20)
            }
            Divider()
            HStack(spacing: 12) {
                if let recording = shortcuts.recording {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shortcuts.recordingError ?? "Press keys for \(recording.action.title.lowercased()).")
                            .font(.callout)
                            .foregroundStyle(shortcuts.recordingError == nil ? Color.secondary : .red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Cancel", action: shortcuts.stopRecording)
                        .buttonStyle(.bordered)
                        .prettyPrintHoverHighlight(.accent)
                        .prettyPrintButtonCursor()
                } else {
                    Text("Return also accepts Enter. Delete also accepts Forward Delete.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Restore defaults", action: shortcuts.restoreDefaults)
                        .buttonStyle(.bordered)
                        .prettyPrintHoverHighlight(.accent)
                        .prettyPrintButtonCursor()
                }
            }
            .frame(minHeight: 42)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func shortcutRow(_ action: PrettyPrintShortcutAction) -> some View {
        let bindings = shortcuts.bindings(for: action)
        return HStack(spacing: 8) {
            Text(action.title).lineLimit(2)
            Spacer(minLength: 8)
            ForEach(Array(bindings.enumerated()), id: \.offset) { index, press in
                HStack(spacing: 1) {
                    recordButton(action, index: index, label: press.label)
                    Button {
                        shortcuts.removeBinding(for: action, at: index)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 24)
                    .prettyPrintHoverHighlight(.destructive, cornerRadius: 4)
                    .prettyPrintButtonCursor()
                    .accessibilityLabel("Clear \(press.label) for \(action.title.lowercased())")
                    .help("Clear shortcut")
                }
            }
            if bindings.count < action.maximumBindings {
                recordButton(action, index: bindings.count, label: bindings.isEmpty ? "Set shortcut" : "+")
            }
        }
        .padding(.vertical, 5)
        .frame(minHeight: 36)
    }

    private func recordButton(_ action: PrettyPrintShortcutAction, index: Int, label: String) -> some View {
        let isRecording = shortcuts.recording?.action == action && shortcuts.recording?.index == index
        return Button {
            shortcuts.beginRecording(action, index: index)
        } label: {
            Text(isRecording ? "Press keys…" : label)
                .font(.system(.callout, design: .monospaced))
                .frame(minWidth: label == "+" ? 12 : 48)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .prettyPrintHoverHighlight(.accent)
        .prettyPrintButtonCursor()
        .accessibilityLabel("\(action.title), \(label == "+" ? "add alternate shortcut" : label)")
        .help("Set shortcut")
    }

    private var heldModifiers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("While dragging").font(.headline)
            Text("Bypass snapping while gridlines are visible")
            HStack(spacing: 16) {
                ForEach(PrettyPrintHeldModifier.allCases) { modifier in
                    Toggle(modifier.label, isOn: Binding(
                        get: { shortcuts.usesSnapBypass(modifier) },
                        set: { shortcuts.setSnapBypass(modifier, enabled: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .prettyPrintButtonCursor()
                }
            }
            Text("Hold any checked key while moving or resizing an image.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Rotate in 15° steps") {
                Picker("Rotate in 15° steps", selection: Binding(
                    get: { shortcuts.rotationStep },
                    set: { shortcuts.rotationStep = $0 }
                )) {
                    Text("None").tag(Optional<PrettyPrintHeldModifier>.none)
                    ForEach(PrettyPrintHeldModifier.allCases) { modifier in
                        Text(modifier.label).tag(Optional(modifier))
                    }
                }
                .labelsHidden()
                .frame(width: 145)
                .prettyPrintButtonCursor()
            }
        }
    }
}
