import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, PopoverFilePickerPresentation {
    private static let fullDiskAccessPromptShownKey = "fullDiskAccessPromptShown"

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverAnchorWindow: NSWindow?
    private var filePickerCoordinator: PopoverFilePickerCoordinator?
    private let composerPresenter = PrintComposerPresenter()
    private let printHistory = PrintHistoryStore()
    private let outsideClicks = OutsideClickMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTextEditingMenu()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = NSImage(
            systemSymbolName: "printer",
            accessibilityDescription: "PrettyPrint"
        )
        button.target = self
        button.action = #selector(togglePopover)

        popover = makePrettyPrintPopover(
            rootView: QueuePanel(
                onChooseFiles: { [weak self] in self?.chooseFiles() ?? [] },
                onCompose: { [weak self] request, completion in
                    self?.presentComposer(request, completion: completion)
                },
                onClosePopover: { [weak self] in self?.closePopover() },
                onQuit: { [weak self] in self?.requestQuit() },
                printHistory: printHistory
            ),
            onDismiss: { [weak self] in self?.closePopover() }
        )
        popover?.delegate = self
        filePickerCoordinator = PopoverFilePickerCoordinator(presentation: self)
        self.statusItem = statusItem

        DispatchQueue.main.async { [weak self] in
            self?.showFullDiskAccessPromptIfNeeded()
        }
    }

    private func installTextEditingMenu() {
        let menu = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        menu.addItem(item)
        NSApp.mainMenu = menu
    }

    private func showFullDiskAccessPromptIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.fullDiskAccessPromptShownKey) else { return }

        let alert = NSAlert()
        alert.messageText = "Allow PrettyPrint Full Disk Access?"
        alert.informativeText = "PrettyPrint can then print documents from any folder without asking again. macOS requires you to enable this once in Privacy & Security."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Later")

        defaults.set(true, forKey: Self.fullDiskAccessPromptShownKey)

        if PrettyPrintShortcuts.shared.runModal(alert) == .alertFirstButtonReturn {
            openFullDiskAccessSettings()
        }
    }

    private func openFullDiskAccessSettings() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ]

        for string in settingsURLs {
            guard let url = URL(string: string), NSWorkspace.shared.open(url) else { continue }
            break
        }
    }

    @objc private func togglePopover() {
        guard let popover else { return }

        if popover.isShown {
            closePopover()
        } else {
            activateApplication()
            showPopover()
        }
    }

    func closePopover() {
        popover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClicks.stop()
        popoverAnchorWindow?.orderOut(nil)
    }

    func activateApplication() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showPopover() {
        guard let button = statusItem?.button,
              let popover,
              let anchorView = popoverAnchorView(for: button) else { return }

        anchorView.window?.orderFrontRegardless()
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)

        if let popoverWindow = popover.contentViewController?.view.window {
            positionPopoverWindow(popoverWindow, below: button)
            popoverWindow.makeKey()
        }
        outsideClicks.start { [weak self] in self?.closePopover() }
    }

    private func positionPopoverWindow(_ window: NSWindow, below button: NSView) {
        guard let buttonWindow = button.window else { return }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        var frame = window.frame
        frame.origin.x = buttonFrameOnScreen.midX - frame.width / 2
        frame.origin.y = buttonFrameOnScreen.minY - frame.height

        if let visibleFrame = buttonWindow.screen?.visibleFrame {
            frame.origin.x = min(
                max(frame.origin.x, visibleFrame.minX),
                visibleFrame.maxX - frame.width
            )
            frame.origin.y = max(frame.origin.y, visibleFrame.minY)
        }

        window.setFrame(frame, display: true)
    }

    private func popoverAnchorView(for button: NSView) -> NSView? {
        guard let buttonWindow = button.window else {
            return nil
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let anchorFrame = NSRect(
            x: buttonFrameOnScreen.midX,
            y: buttonFrameOnScreen.minY,
            width: 1,
            height: 1
        )

        let anchorWindow: NSWindow
        if let existingWindow = popoverAnchorWindow {
            anchorWindow = existingWindow
            anchorWindow.setFrame(anchorFrame, display: false)
        } else {
            anchorWindow = NSWindow(
                contentRect: anchorFrame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            anchorWindow.isOpaque = false
            anchorWindow.backgroundColor = .clear
            anchorWindow.alphaValue = 0.01
            anchorWindow.hasShadow = false
            anchorWindow.ignoresMouseEvents = true
            anchorWindow.level = .statusBar
            anchorWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            anchorWindow.contentView = NSView(frame: NSRect(origin: .zero, size: anchorFrame.size))
            popoverAnchorWindow = anchorWindow
        }

        return anchorWindow.contentView
    }

    private func chooseFiles() -> [URL] {
        filePickerCoordinator?.chooseFiles() ?? []
    }

    private func presentComposer(
        _ request: PrintComposerRequest,
        completion: @escaping (PrintComposerResult?) -> Void
    ) {
        closePopover()
        activateApplication()
        composerPresenter.present(request) { [weak self] result in
            self?.showPopover()
            completion(result)
        }
    }

    private func requestQuit() {
        closePopover()
        activateApplication()

        let alert = NSAlert()
        alert.messageText = "Quit PrettyPrint?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        if PrettyPrintShortcuts.shared.runModal(alert) == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        } else {
            showPopover()
        }
    }
}
