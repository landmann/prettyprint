import AppKit
import SwiftUI

struct PrettyPrintKeyPress: Codable, Equatable {
    let key: String
    let modifiers: UInt

    init(_ key: String, _ flags: NSEvent.ModifierFlags = []) {
        self.key = key
        modifiers = flags.intersection([.command, .control, .option, .shift]).rawValue
    }

    init?(_ event: NSEvent) {
        let key: String
        switch event.keyCode {
        case 36, 76: key = "return"
        case 53: key = "escape"
        case 49: key = "space"
        case 51, 117: key = "delete"
        case 48: key = "tab"
        case 69: key = "="
        case 78: key = "-"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 115: key = "home"
        case 119: key = "end"
        case 116: key = "pageUp"
        case 121: key = "pageDown"
        default:
            guard let characters = event.characters(byApplyingModifiers: []),
                  !characters.isEmpty,
                  !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            key = characters.lowercased()
        }
        self.init(key, event.modifierFlags)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var label: String {
        let prefix = (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "")
        let names = ["return": "↩", "escape": "Esc", "space": "Space", "delete": "⌫", "tab": "⇥",
                     "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘",
                     "pageUp": "⇞", "pageDown": "⇟"]
        if let name = names[key] { return prefix + name }
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
           scalar.value >= UInt32(NSF1FunctionKey), scalar.value <= UInt32(NSF35FunctionKey) {
            return prefix + "F\(scalar.value - UInt32(NSF1FunctionKey) + 1)"
        }
        return prefix + key.uppercased()
    }

    var keyEquivalent: String {
        let names = ["return": "\r", "escape": "\u{1b}", "space": " ", "delete": "\u{7f}", "tab": "\t",
                     "left": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "right": String(UnicodeScalar(NSRightArrowFunctionKey)!),
                     "up": String(UnicodeScalar(NSUpArrowFunctionKey)!), "down": String(UnicodeScalar(NSDownArrowFunctionKey)!),
                     "home": String(UnicodeScalar(NSHomeFunctionKey)!), "end": String(UnicodeScalar(NSEndFunctionKey)!),
                     "pageUp": String(UnicodeScalar(NSPageUpFunctionKey)!), "pageDown": String(UnicodeScalar(NSPageDownFunctionKey)!)]
        return names[key] ?? key
    }
}

enum PrettyPrintShortcutScope: Hashable {
    case queue, editor, history, settings, dialog
}

enum PrettyPrintShortcutAction: String, CaseIterable, Identifiable {
    case settings, addFiles, rename, close, history
    case blankCanvas, printFiles, quit, printer1, printer2, printer3, printer4, printer5, refreshPrinters, addPrinter
    case previousFile, nextFile, preview, removeFile, moreCopies, fewerCopies
    case selectAll, copy, paste, duplicate, removeImage, fit, center, reset, done, cancel, deselect
    case addText, editText, textFont, largerText, smallerText
    case previousImage, nextImage, aspect, rotateLeft, rotateRight, previousPage, nextPage
    case grid, moreHorizontal, fewerHorizontal, moreVertical, fewerVertical
    case moveLeft, moveRight, moveUp, moveDown, moveLeftFast, moveRightFast, moveUpFast, moveDownFast
    case addHistory1 = "reprint1"
    case addHistory2 = "reprint2"
    case addHistory3 = "reprint3"
    case addHistory4 = "reprint4"
    case addHistory5 = "reprint5"
    case confirmDialog, cancelDialog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: "Open settings"
        case .addFiles: "Add files"
        case .rename: "Rename original file"
        case .close: "Close popover or settings"
        case .history: "Open / close print history"
        case .blankCanvas: "Start from blank canvas"
        case .printFiles: "Print queued files"
        case .quit: "Quit PrettyPrint"
        case .printer1: "Select first printer"
        case .printer2: "Select second printer"
        case .printer3: "Select third printer"
        case .printer4: "Select fourth printer"
        case .printer5: "Select fifth printer"
        case .refreshPrinters: "Refresh printer status"
        case .addPrinter: "Add printer"
        case .previousFile: "Select previous file"
        case .nextFile: "Select next file"
        case .preview: "Edit selected file"
        case .removeFile: "Remove selected file"
        case .moreCopies: "Increase print copies"
        case .fewerCopies: "Decrease print copies"
        case .addText: "Add text"
        case .editText: "Edit selected text"
        case .textFont: "Cycle text font"
        case .largerText: "Increase font size"
        case .smallerText: "Decrease font size"
        case .selectAll: "Select all layers"
        case .copy: "Copy selected layers"
        case .paste: "Paste layers"
        case .duplicate: "Duplicate selected layers"
        case .removeImage: "Remove selected layers"
        case .fit: "Fit selection to page"
        case .center: "Center selection"
        case .reset: "Reset layout"
        case .done: "Save layout"
        case .cancel: "Cancel editing"
        case .deselect: "Deselect layers / close editor"
        case .previousImage: "Select previous item"
        case .nextImage: "Select next item"
        case .aspect: "Cycle aspect ratio"
        case .rotateLeft: "Rotate left 90°"
        case .rotateRight: "Rotate right 90°"
        case .previousPage: "Previous page"
        case .nextPage: "Next page"
        case .grid: "Show / hide gridlines"
        case .moreHorizontal: "Add horizontal gridline"
        case .fewerHorizontal: "Remove horizontal gridline"
        case .moreVertical: "Add vertical gridline"
        case .fewerVertical: "Remove vertical gridline"
        case .moveLeft: "Move left 1 pt"
        case .moveRight: "Move right 1 pt"
        case .moveUp: "Move up 1 pt"
        case .moveDown: "Move down 1 pt"
        case .moveLeftFast: "Move left 10 pt"
        case .moveRightFast: "Move right 10 pt"
        case .moveUpFast: "Move up 10 pt"
        case .moveDownFast: "Move down 10 pt"
        case .addHistory1: "Add most recent file to queue"
        case .addHistory2: "Add second file to queue"
        case .addHistory3: "Add third file to queue"
        case .addHistory4: "Add fourth file to queue"
        case .addHistory5: "Add fifth file to queue"
        case .confirmDialog: "Confirm dialog"
        case .cancelDialog: "Cancel dialog"
        }
    }

    var group: String {
        switch self {
        case .settings, .addFiles, .rename, .close, .history: "General"
        case .blankCanvas, .printFiles, .quit, .printer1, .printer2, .printer3, .printer4, .printer5, .refreshPrinters, .addPrinter,
             .previousFile, .nextFile, .preview, .removeFile, .moreCopies, .fewerCopies: "Print queue"
        case .addHistory1, .addHistory2, .addHistory3, .addHistory4, .addHistory5: "Print history"
        case .confirmDialog, .cancelDialog: "Dialogs"
        default: "Editor"
        }
    }

    var scopes: Set<PrettyPrintShortcutScope> {
        switch self {
        case .settings: [.queue, .history, .editor, .settings]
        case .addFiles, .rename: [.queue, .editor]
        case .close: [.queue, .history, .settings]
        case .history: [.queue, .history]
        default:
            switch group {
            case "Print queue": [.queue]
            case "Print history": [.history]
            case "Dialogs": [.dialog]
            default: [.editor]
            }
        }
    }

    var defaults: [PrettyPrintKeyPress] {
        switch self {
        case .settings: [.init(",", .command)]
        case .addFiles: [.init("o", .command)]
        case .rename: [.init("r", [.command, .shift])]
        case .close, .deselect: [.init("escape")]
        case .history: [.init("y", .command)]
        case .blankCanvas: [.init("n", .command)]
        case .printFiles: [.init("p", .command)]
        case .quit: [.init("q", .command)]
        case .printer1: [.init("1", .command)]
        case .printer2: [.init("2", .command)]
        case .printer3: [.init("3", .command)]
        case .printer4: [.init("4", .command)]
        case .printer5: [.init("5", .command)]
        case .refreshPrinters: [.init("r", .command)]
        case .addPrinter: [.init("n", [.command, .shift])]
        case .previousFile: [.init("left")]
        case .nextFile: [.init("right")]
        case .preview: [.init("space")]
        case .removeFile, .removeImage: [.init("delete")]
        case .moreCopies: [.init("="), .init("=", .shift)]
        case .fewerCopies: [.init("-")]
        case .addText: [.init("t", [.command, .shift])]
        case .editText: [.init("e", [.command, .shift])]
        case .textFont: [.init("f", [.command, .shift])]
        case .largerText: [.init(".", [.command, .shift])]
        case .smallerText: [.init(",", [.command, .shift])]
        case .selectAll: [.init("a", .command), .init("a", .control)]
        case .copy: [.init("c", .command), .init("c", .control)]
        case .paste: [.init("v", .command), .init("v", .control)]
        case .duplicate: [.init("d", .command)]
        case .fit: [.init("f", .command)]
        case .center: [.init("e", .command)]
        case .reset: [.init("r", .command)]
        case .done: [.init("return"), .init("return", .command)]
        case .cancel: [.init(".", .command)]
        case .previousImage: [.init("up", .command)]
        case .nextImage: [.init("down", .command)]
        case .aspect: [.init("a", [.command, .shift])]
        case .rotateLeft: [.init("[", .command)]
        case .rotateRight: [.init("]", .command)]
        case .previousPage: [.init("left")]
        case .nextPage: [.init("right")]
        case .grid: [.init("g", .command)]
        case .moreHorizontal: [.init("up", [.command, .option])]
        case .fewerHorizontal: [.init("down", [.command, .option])]
        case .moreVertical: [.init("right", [.command, .option])]
        case .fewerVertical: [.init("left", [.command, .option])]
        case .moveLeft: [.init("left", .option)]
        case .moveRight: [.init("right", .option)]
        case .moveUp: [.init("up")]
        case .moveDown: [.init("down")]
        case .moveLeftFast: [.init("left", .shift)]
        case .moveRightFast: [.init("right", .shift)]
        case .moveUpFast: [.init("up", .shift)]
        case .moveDownFast: [.init("down", .shift)]
        case .addHistory1: [.init("1", [.command, .option])]
        case .addHistory2: [.init("2", [.command, .option])]
        case .addHistory3: [.init("3", [.command, .option])]
        case .addHistory4: [.init("4", [.command, .option])]
        case .addHistory5: [.init("5", [.command, .option])]
        case .confirmDialog: [.init("return")]
        case .cancelDialog: [.init("escape")]
        }
    }

    var maximumBindings: Int { scopes.contains(.dialog) ? 1 : 2 }
}

enum PrettyPrintHeldModifier: String, Codable, CaseIterable, Identifiable {
    case control, option, shift, command
    var id: String { rawValue }
    var label: String {
        switch self {
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .shift: "⇧ Shift"
        case .command: "⌘ Command"
        }
    }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }
}

@MainActor
final class PrettyPrintShortcuts: ObservableObject {
    static let shared = PrettyPrintShortcuts()
    private static let defaultsKey = "keyboardShortcuts"

    private struct Preferences: Codable {
        var bindings: [String: [PrettyPrintKeyPress]] = [:]
        var snapBypass: Set<PrettyPrintHeldModifier> = [.control, .command]
        var rotationStep: PrettyPrintHeldModifier? = .shift
    }

    @Published private var preferences: Preferences
    @Published var recording: (action: PrettyPrintShortcutAction, index: Int)?
    @Published var recordingError: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            preferences = saved
        } else {
            preferences = Preferences()
        }
    }

    func bindings(for action: PrettyPrintShortcutAction) -> [PrettyPrintKeyPress] {
        preferences.bindings[action.rawValue] ?? action.defaults
    }

    func action(for press: PrettyPrintKeyPress, in scope: PrettyPrintShortcutScope) -> PrettyPrintShortcutAction? {
        guard recording == nil else { return nil }
        return PrettyPrintShortcutAction.allCases.first {
            $0.scopes.contains(scope) && bindings(for: $0).contains(press)
        }
    }

    func beginRecording(_ action: PrettyPrintShortcutAction, index: Int) {
        recordingError = nil
        recording = (action, index)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func stopRecording() {
        recording = nil
        recordingError = nil
    }

    func record(_ event: NSEvent) {
        guard !event.isARepeat, let recording else { return }
        guard let press = PrettyPrintKeyPress(event) else {
            recordingError = "Choose a letter, number, arrow, or function key."
            return
        }
        if recording.action.scopes.contains(.dialog), press.flags.intersection([.command, .control, .option]).isEmpty,
           !["return", "escape"].contains(press.key) {
            recordingError = "Use Command, Control, or Option so this shortcut does not interrupt typing in dialogs."
            return
        }
        if let conflict = PrettyPrintShortcutAction.allCases.first(where: {
            $0 != recording.action && !$0.scopes.isDisjoint(with: recording.action.scopes) && bindings(for: $0).contains(press)
        }) {
            recordingError = "\(press.label) is already used for \(conflict.title.lowercased())."
            return
        }
        var current = bindings(for: recording.action)
        if current.enumerated().contains(where: { $0.offset != recording.index && $0.element == press }) {
            recordingError = "This action already uses \(press.label)."
            return
        }
        if current.indices.contains(recording.index) {
            current[recording.index] = press
        } else {
            guard current.count < recording.action.maximumBindings else { return }
            current.append(press)
        }
        preferences.bindings[recording.action.rawValue] = current
        save()
        stopRecording()
    }

    func removeBinding(for action: PrettyPrintShortcutAction, at index: Int) {
        var current = bindings(for: action)
        guard current.indices.contains(index) else { return }
        current.remove(at: index)
        preferences.bindings[action.rawValue] = current
        save()
        stopRecording()
    }

    func bypassesSnapping(_ flags: NSEvent.ModifierFlags) -> Bool {
        preferences.snapBypass.contains { flags.contains($0.flag) }
    }

    func usesSnapBypass(_ modifier: PrettyPrintHeldModifier) -> Bool {
        preferences.snapBypass.contains(modifier)
    }

    func setSnapBypass(_ modifier: PrettyPrintHeldModifier, enabled: Bool) {
        if enabled { preferences.snapBypass.insert(modifier) } else { preferences.snapBypass.remove(modifier) }
        save()
    }

    var rotationStep: PrettyPrintHeldModifier? {
        get { preferences.rotationStep }
        set { preferences.rotationStep = newValue; save() }
    }

    func usesRotationSteps(_ flags: NSEvent.ModifierFlags) -> Bool {
        preferences.rotationStep.map { flags.contains($0.flag) } ?? false
    }

    func restoreDefaults() {
        preferences = Preferences()
        save()
        stopRecording()
    }

    @discardableResult
    func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        for (index, button) in alert.buttons.enumerated() {
            let action: PrettyPrintShortcutAction = index == 0 ? .confirmDialog : .cancelDialog
            let press = bindings(for: action).first
            button.keyEquivalent = press?.keyEquivalent ?? ""
            button.keyEquivalentModifierMask = press?.flags ?? []
        }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak alert] event in
            guard let self, let alert, event.window === alert.window,
                  NSApp.modalWindow === alert.window, let press = PrettyPrintKeyPress(event) else { return event }
            switch self.action(for: press, in: .dialog) {
            case .confirmDialog: alert.buttons.first?.performClick(nil); return nil
            case .cancelDialog: alert.buttons.last?.performClick(nil); return nil
            default: return ["return", "escape"].contains(press.key) ? nil : event
            }
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

struct PrettyPrintKeyMonitor: NSViewRepresentable {
    let onKeyDown: (PrettyPrintKeyPress) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) { nsView.onKeyDown = onKeyDown }
    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) { nsView.removeMonitor() }

    final class MonitorView: NSView {
        var onKeyDown: ((PrettyPrintKeyPress) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
                      !(window.firstResponder is NSTextView),
                      let press = PrettyPrintKeyPress(event), self.onKeyDown?(press) == true else { return event }
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension View {
    func prettyPrintKeyMonitor(_ onKeyDown: @escaping (PrettyPrintKeyPress) -> Bool) -> some View {
        background(PrettyPrintKeyMonitor(onKeyDown: onKeyDown).allowsHitTesting(false))
    }
}
