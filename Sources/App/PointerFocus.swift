import AppKit

@MainActor
enum PrettyPrintPointerFocus {
    static func dismiss() {
        dismiss(in: NSApp.keyWindow)
    }

    static func dismiss(in window: NSWindow?) {
        window?.makeFirstResponder(nil)
    }
}
