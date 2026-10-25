import AppKit
import SwiftUI

@MainActor
private final class DismissibleHostingController<Content: View>: NSHostingController<Content> {
    private let onDismiss: () -> Void

    init(rootView: Content, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cancelOperation(_ sender: Any?) {
        guard let event = NSApp.currentEvent, let press = PrettyPrintKeyPress(event),
              PrettyPrintShortcuts.shared.action(for: press, in: .queue) == .close else { return }
        onDismiss()
    }
}

@MainActor
func makePrettyPrintPopover<Content: View>(
    rootView: Content,
    onDismiss: @escaping () -> Void
) -> NSPopover {
    let popover = NSPopover()
    popover.behavior = .applicationDefined
    popover.animates = true
    popover.appearance = NSAppearance(named: .darkAqua)
    if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
        popover.setValue(true, forKey: "shouldHideAnchor")
    }
    popover.contentViewController = DismissibleHostingController(
        rootView: rootView,
        onDismiss: onDismiss
    )
    return popover
}
