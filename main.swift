import SwiftUI
import AppKit
import QuickLookThumbnailing
import ServiceManagement
import UniformTypeIdentifiers

private let prettyPrintDropBlue = Color(red: 0.38, green: 0.66, blue: 1)
private let prettyPrintDocumentExitDuration = 0.28
private let prettyPrintResultHoldDuration = 1.4

@main
struct PrettyPrintApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, PopoverFilePickerPresentation {
    private static let fullDiskAccessPromptShownKey = "fullDiskAccessPromptShown"

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverAnchorWindow: NSWindow?
    private var filePickerCoordinator: PopoverFilePickerCoordinator?
    private let composerPresenter = PrintComposerPresenter()
    private let printHistory = PrintHistoryStore()

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
            rootView: ContentView(
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

private enum PrintResultPresentation: Equatable {
    case success
    case failure(partial: Bool)

    var message: String {
        switch self {
        case .success:
            "Files sent to printer!"
        case .failure(let partial):
            partial ? "Some files couldn’t be sent" : "Files couldn’t be sent"
        }
    }

    var isSuccess: Bool {
        self == .success
    }
}

struct ContentView: View {
    private static let headerIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    let onChooseFiles: () -> [URL]
    let onCompose: (PrintComposerRequest, @escaping (PrintComposerResult?) -> Void) -> Void
    let onClosePopover: () -> Void
    let onQuit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("printer") var printer = ""
    @State private var queuedDocuments: [QueuedDocument] = []
    @State var statusMessage = ""
    @State private var isPrinting = false
    @State private var printProgress: PrintBatchProgress?
    @State private var isClearingPrintResult = false
    @State private var printResultPresentation: PrintResultPresentation?
    @State private var printResultTask: Task<Void, Never>?
    @State private var isShowingPrintHistory = false
    @State private var nextDropSequence = 0
    @State private var nextDropToAppend = 0
    @State private var pendingDropBatches: [Int: [URL]] = [:]
    @State private var navbarDraggedFileCount = 0
    private let documentStager = PrettyPrintDocumentStager()
    @StateObject private var printers = PrinterStore()
    @State private var hasManualPrinterSelection = false
    @ObservedObject var printHistory: PrintHistoryStore
    @ObservedObject private var renameCoordinator = FileRenameCoordinator.shared
    @State private var selectedDocumentID: QueuedDocument.ID?
    var body: some View {
        VStack(spacing: 10) {
            navbarHeader
            printerList
            Divider()
            fileDropSurface
            HStack(spacing: 8) {
                Button(action: onQuit) {
                    Text("Quit")
                }
                    .buttonStyle(PrettyPrintTileButtonStyle(size: .row, tint: .destructive))
                    .prettyPrintHoverHighlight(.destructive)
                    .prettyPrintButtonCursor()

                Button(action: startBlankCanvas) {
                    Text(isPrinting ? printingLabel : blankDocumentLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrettyPrintTileButtonStyle(size: .row))
                .prettyPrintHoverHighlight(.accent)
                .prettyPrintButtonCursor()
                .disabled(isQueueLocked || isPresentingPrintResult)

                Button { doPrint() } label: {
                    Text("Print")
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .environment(\.controlActiveState, .active)
                    .disabled(!canPrint)
                    .prettyPrintHoverHighlight(.primary)
                    .prettyPrintButtonCursor()
            }
            if !isPrinting && !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(width: 280)
        .padding(12)
        .background(Color.black.opacity(0.85))
        .focusEffectDisabled()
        .prettyPrintKeyMonitor(handleKeyPress)
        .onAppear {
            try? SMAppService.mainApp.register()
            printers.refresh()
        }
        .task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                printers.refresh()
            }
        }
        .onChange(of: printers.printers) {
            updateAutomaticPrinterSelection()
        }
        .onChange(of: printers.defaultPrinterID) {
            updateAutomaticPrinterSelection()
        }
        .onDisappear {
            resetPrintResultPresentation()
        }
    }

    private var selectedPrinterCanPrint: Bool {
        printers.printer(printer)?.status.canPrint ?? false
    }

    private var isPresentingPrintResult: Bool {
        isClearingPrintResult || printResultPresentation != nil
    }

    private var canPrint: Bool {
        !queuedDocuments.isEmpty
            && !isPrinting
            && !isPresentingPrintResult
            && selectedPrinterCanPrint
    }

    private var blankDocumentLabel: String {
        queuedDocuments.isEmpty ? "Start from blank canvas" : "New blank document"
    }

    private var isQueueLocked: Bool {
        isPrinting || isClearingPrintResult
    }

    private var printingLabel: String {
        guard let printProgress else { return "Printing…" }
        return "Printing… \(printProgress.submittedCopies)/\(printProgress.totalCopies)"
    }

    private var selectedDocument: QueuedDocument? {
        queuedDocuments.first { $0.id == selectedDocumentID } ?? queuedDocuments.first
    }

    private var isShowingQueue: Bool {
        printResultPresentation == nil && !queuedDocuments.isEmpty
    }

    private func handleKeyPress(_ press: PrettyPrintKeyPress) -> Bool {
        guard let action = PrettyPrintShortcuts.shared.action(for: press, in: .queue) else { return false }
        switch action {
        case .settings: showShortcutSettings()
        case .close: onClosePopover()
        case .previousFile: return moveSelection(by: -1)
        case .nextFile: return moveSelection(by: 1)
        case .preview:
            guard isShowingQueue, !isQueueLocked, let document = selectedDocument else { return true }
            openComposer(for: document.id)
        case .removeFile:
            guard isShowingQueue, !isQueueLocked, let document = selectedDocument else { return true }
            removeFile(id: document.id)
        case .moreCopies: return changeSelectedCopies(by: 1)
        case .fewerCopies: return changeSelectedCopies(by: -1)
        case .addFiles:
            guard !isPrinting, !isPresentingPrintResult else { return true }
            chooseFiles()
        case .blankCanvas: startBlankCanvas()
        case .printFiles: if canPrint { doPrint() }
        case .quit: onQuit()
        case .history: isShowingPrintHistory.toggle()
        case .rename:
            guard isShowingQueue, !isQueueLocked, let document = selectedDocument else { return true }
            renameCoordinator.rename(document.originalFileURL, relativeTo: NSApp.keyWindow)
        case .printer1: selectPrinter(at: 0)
        case .printer2: selectPrinter(at: 1)
        case .printer3: selectPrinter(at: 2)
        case .printer4: selectPrinter(at: 3)
        case .printer5: selectPrinter(at: 4)
        case .refreshPrinters: printers.refresh()
        case .addPrinter: showAddPrinter()
        default: return false
        }
        return true
    }

    private func showShortcutSettings() {
        isShowingPrintHistory = false
        onClosePopover()
        PrettyPrintSettingsPresenter.shared.show()
    }

    private func selectPrinter(_ id: String) {
        hasManualPrinterSelection = true
        printer = id
    }

    private func selectPrinter(at index: Int) {
        guard printers.printers.indices.contains(index) else { return }
        selectPrinter(printers.printers[index].id)
    }

    private func showAddPrinter() {
        isShowingPrintHistory = false
        onClosePopover()
        AddPrinterPresenter.shared.show { printers.refresh() }
    }

    private func moveSelection(by offset: Int) -> Bool {
        guard isShowingQueue,
              let current = selectedDocument,
              let index = queuedDocuments.firstIndex(where: { $0.id == current.id }) else { return false }
        let target = min(max(index + offset, 0), queuedDocuments.count - 1)
        selectedDocumentID = queuedDocuments[target].id
        return true
    }

    private func changeSelectedCopies(by delta: Int) -> Bool {
        guard isShowingQueue, !isQueueLocked, let document = selectedDocument else { return false }
        updateCopies(id: document.id, copies: document.copies + delta)
        return true
    }

    private var navbarHeader: some View {
        HStack(spacing: 8) {
            if let icon = Self.headerIcon {
                Image(nsImage: icon)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
            Text("PrettyPrint").font(.headline)
            Spacer()
            if !printers.printers.isEmpty {
                Button(action: showAddPrinter) {
                    Image(systemName: "plus")
                }
                .buttonStyle(PrettyPrintTileButtonStyle(size: .small))
                .accessibilityLabel("Add printer")
                .help("Add printer")
                .prettyPrintHoverHighlight(.accent, cornerRadius: 5)
                .prettyPrintButtonCursor()
            }
            Button(action: showShortcutSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(PrettyPrintTileButtonStyle(size: .small))
            .accessibilityLabel("Settings")
            .help("Settings")
            .prettyPrintHoverHighlight(.accent, cornerRadius: 5)
            .prettyPrintButtonCursor()
            Button {
                isShowingPrintHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(PrettyPrintTileButtonStyle(size: .small))
            .accessibilityLabel("Print history")
            .help("Print history")
            .prettyPrintHoverHighlight(.accent, cornerRadius: 5)
            .prettyPrintButtonCursor()
            .popover(isPresented: $isShowingPrintHistory, arrowEdge: .top) {
                printHistoryPopover
            }
            Button(action: onClosePopover) {
                Image(systemName: "xmark")
            }
            .buttonStyle(PrettyPrintTileButtonStyle(size: .small))
            .accessibilityLabel("Close PrettyPrint")
            .help("Close PrettyPrint")
            .prettyPrintHoverHighlight(.accent, cornerRadius: 5)
            .prettyPrintButtonCursor()
        }
        .overlay {
            if navbarDraggedFileCount > 0 {
                navbarDropOverlay
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [.fileURL],
            delegate: NavbarFileDropDelegate(
                onTargeted: { navbarDraggedFileCount = $0 },
                onExited: { navbarDraggedFileCount = 0 },
                onPerform: handleDrop
            )
        )
    }

    private var printHistoryPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Print history")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

            if printHistory.records.isEmpty {
                Text("No printed documents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            } else {
                ForEach(Array(printHistory.records.enumerated()), id: \.element.id) { index, record in
                    let fileName = renameCoordinator.displayName(for: record.fileURL)
                    if index > 0 {
                        Divider()
                            .padding(.leading, 34)
                            .padding(.trailing, 8)
                    }

                    Button {
                        addHistoryToQueue(record)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(fileName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Text(record.printedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 4)

                            Image(systemName: "plus")
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 20)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Add \(fileName) to queue")
                    .accessibilityValue(record.printedAt.formatted(date: .abbreviated, time: .shortened))
                    .help("Add to queue")
                    .prettyPrintHoverHighlight(.row, cornerRadius: 6)
                    .prettyPrintButtonCursor()
                    .disabled(isPrinting || isPresentingPrintResult)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
        .frame(width: 260)
        .prettyPrintKeyMonitor(handleHistoryKeyPress)
    }

    private func handleHistoryKeyPress(_ press: PrettyPrintKeyPress) -> Bool {
        guard let action = PrettyPrintShortcuts.shared.action(for: press, in: .history) else { return false }
        switch action {
        case .close, .history:
            isShowingPrintHistory = false
        case .settings:
            showShortcutSettings()
        case .addHistory1, .addHistory2, .addHistory3, .addHistory4, .addHistory5:
            let actions: [PrettyPrintShortcutAction] = [.addHistory1, .addHistory2, .addHistory3, .addHistory4, .addHistory5]
            guard let index = actions.firstIndex(of: action), printHistory.records.indices.contains(index) else { return true }
            if !isPrinting && !isPresentingPrintResult { addHistoryToQueue(printHistory.records[index]) }
        default: return false
        }
        return true
    }

    private var navbarDropOverlay: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                Text(navbarDropLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
            }
    }

    private var navbarDropLabel: String {
        let noun = navbarDraggedFileCount == 1 ? "file" : "files"
        return "Drop \(navbarDraggedFileCount) \(noun)"
    }

    private var fileDropSurface: some View {
        ZStack {
            if let printResultPresentation {
                printResultFeedback(printResultPresentation)
                    .transition(printResultTransition)
            } else if isClearingPrintResult || !queuedDocuments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(queuedDocuments) { document in
                            fileThumbnailItem(document: document)
                        }
                    }
                    .padding(10)
                }
                .transition(.opacity)
            } else {
                Button(action: chooseFiles) {
                    Text("Drag & Drop or pick a file to print")
                        .font(.caption)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PrettyPrintFileDropButtonStyle())
                .accessibilityLabel("Drag & Drop or pick a file to print")
                .help("Choose files to print")
                .prettyPrintButtonCursor()
                .transition(.opacity)
            }

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    prettyPrintDropBlue.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, dash: [4])
                )
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: fileDropSurfaceHeight)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .animation(
            reduceMotion ? .linear(duration: 0.08) : .easeOut(duration: 0.2),
            value: fileDropSurfaceHeight
        )
    }

    private var fileDropSurfaceHeight: CGFloat {
        isPresentingPrintResult || !queuedDocuments.isEmpty ? 150 : 112
    }

    private var printResultTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }

        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.9)),
            removal: .opacity.combined(with: .scale(scale: 0.98))
        )
    }

    private var documentExitTransition: AnyTransition {
        let removal: AnyTransition = reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.96))
        return .asymmetric(insertion: .identity, removal: removal)
    }

    private func printResultFeedback(_ presentation: PrintResultPresentation) -> some View {
        let color = presentation.isSuccess ? Color.green : Color.red
        let symbolName = presentation.isSuccess ? "checkmark" : "exclamationmark"

        return VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                Circle()
                    .strokeBorder(color.opacity(0.24), lineWidth: 1)
                Image(systemName: symbolName)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            Text(presentation.message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.message)
    }

    private func chooseFiles() {
        let selectedURLs = onChooseFiles()
        guard !selectedURLs.isEmpty else { return }

        resetPrintResultPresentation()
        let result = documentStager.stage(selectedURLs)
        let stagedDocuments = result.urls.map { QueuedDocument(fileURL: $0) }
        queuedDocuments.append(contentsOf: stagedDocuments)
        statusMessage = stagingStatusMessage(for: result.failedCount)
        openComposer(for: stagedDocuments.first?.id)
    }

    private func startBlankCanvas() {
        guard !isQueueLocked, !isPresentingPrintResult else { return }
        presentEditor(selectedDocumentID: nil, startsFromBlankCanvas: true)
    }

    private func openComposer(for id: QueuedDocument.ID?) {
        guard let id, !isPrinting, queuedDocuments.contains(where: { $0.id == id }) else { return }
        presentEditor(selectedDocumentID: id)
    }

    private func presentEditor(selectedDocumentID: QueuedDocument.ID?, startsFromBlankCanvas: Bool = false) {
        onCompose(PrintComposerRequest(
            documents: queuedDocuments,
            selectedDocumentID: selectedDocumentID,
            paper: printers.paper(for: printer),
            printerID: printer,
            startsFromBlankCanvas: startsFromBlankCanvas
        )) { result in
            guard let result else { return }
            resetPrintResultPresentation()
            let addedWhileEditing = queuedDocuments.filter { !result.originalDocumentIDs.contains($0.id) }
            queuedDocuments = result.documents + addedWhileEditing
            self.selectedDocumentID = result.selectedDocumentID
            statusMessage = ""
        }
    }

    private func fileThumbnailItem(document: QueuedDocument) -> some View {
        PrettyPrintDocumentThumbnailItem(
            document: document,
            isPrinting: isQueueLocked,
            isSelected: document.id == selectedDocument?.id,
            onSelect: { selectedDocumentID = $0 },
            onPreview: { openComposer(for: $0) },
            onRemove: { removeFile(id: $0) },
            onCopiesChange: { id, copies in updateCopies(id: id, copies: copies) }
        )
        .transition(documentExitTransition)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        let sequence = nextDropSequence
        nextDropSequence += 1
        var resolvedURLs = Array<URL?>(repeating: nil, count: providers.count)
        var remainingProviders = providers.count

        func finish(index: Int, url: URL?) {
            DispatchQueue.main.async {
                resolvedURLs[index] = url
                remainingProviders -= 1

                guard remainingProviders == 0 else { return }
                self.pendingDropBatches[sequence] = resolvedURLs.compactMap { $0 }
                self.flushPendingDropBatches()
            }
        }

        for (index, provider) in providers.enumerated() {
            guard provider.canLoadObject(ofClass: URL.self) else {
                finish(index: index, url: nil)
                continue
            }

            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                finish(index: index, url: object)
            }
        }

        return true
    }

    private func flushPendingDropBatches() {
        while let batch = pendingDropBatches.removeValue(forKey: nextDropToAppend) {
            nextDropToAppend += 1
            guard !batch.isEmpty else { continue }

            resetPrintResultPresentation()
            let result = documentStager.stage(batch)
            let stagedDocuments = result.urls.map { QueuedDocument(fileURL: $0) }
            queuedDocuments.append(contentsOf: stagedDocuments)
            statusMessage = stagingStatusMessage(for: result.failedCount)
            openComposer(for: stagedDocuments.first?.id)
        }
    }

    private func removeFile(id: QueuedDocument.ID) {
        if id == selectedDocument?.id, let index = queuedDocuments.firstIndex(where: { $0.id == id }) {
            let remaining = queuedDocuments.filter { $0.id != id }
            selectedDocumentID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        queuedDocuments.removeAll { $0.id == id }
        if queuedDocuments.isEmpty {
            statusMessage = ""
        }
    }

    private func updateCopies(id: QueuedDocument.ID, copies: Int) {
        let copies = QueuedDocument.clampedCopies(copies)
        queuedDocuments = queuedDocuments.map { document in
            guard document.id == id else { return document }
            var updatedDocument = document
            updatedDocument.copies = copies
            return updatedDocument
        }
    }

    private func stagingStatusMessage(for failedCount: Int) -> String {
        guard failedCount > 0 else { return "" }
        let noun = failedCount == 1 ? "file" : "files"
        return "Couldn’t add \(failedCount) \(noun)"
    }
    @ViewBuilder
    private var printerList: some View {
        if !printers.printers.isEmpty {
            ForEach(printers.printers) { printer in
                printerRow(title: printer.name, id: printer.id, status: printer.status, onRefresh: printers.refresh)
            }
        } else if printers.hasLoaded {
            Button(action: showAddPrinter) {
                Label("Add printer", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrettyPrintTileButtonStyle(size: .row))
            .prettyPrintHoverHighlight(.accent)
            .prettyPrintButtonCursor()
        } else {
            PrettyPrintCheckingDots()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Loading printers")
        }
    }

    private func printerRow(
        title: String,
        id: String,
        status: Status,
        onRefresh: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Button {
                selectPrinter(id)
            } label: {
                HStack {
                    Image(systemName: printer == id ? "largecircle.fill.circle" : "circle")
                    Text(title)
                    Spacer()
                    Circle()
                        .fill(status == .checking || status == .unchecked ? Color.gray : status.canPrint ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(status.title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PrettyPrintTileButtonStyle(size: .row))
            .prettyPrintHoverHighlight(.selection)
            .prettyPrintButtonCursor()

            if !status.canPrint {
                Button {
                    guard status != .checking else { return }
                    onRefresh()
                } label: {
                    if status == .checking {
                        PrettyPrintCheckingDots()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(PrettyPrintTileButtonStyle(size: .icon))
                .accessibilityLabel(
                    status == .checking
                        ? "Checking \(title) status"
                        : "Refresh \(title) status"
                )
                .help(status == .checking ? "Checking \(title)" : "Check \(title) again")
                .prettyPrintHoverHighlight(.accent)
                .prettyPrintButtonCursor()
                .disabled(status == .checking)
                .transition(.opacity)
            }
        }
        .animation(prettyPrintHoverAnimation, value: status)
    }
    private func updateAutomaticPrinterSelection() {
        printer = PrinterSelectionPolicy.automaticSelection(
            currentPrinter: printer,
            printers: printers.printers,
            defaultPrinterID: printers.defaultPrinterID,
            hasManualPrinterSelection: hasManualPrinterSelection
        )
    }
    private func doPrint() {
        guard canPrint else { return }

        submitPrint(queuedDocuments)
    }

    private func addHistoryToQueue(_ record: PrintedDocumentRecord) {
        guard !isPrinting, !isPresentingPrintResult else { return }

        isShowingPrintHistory = false
        resetPrintResultPresentation()
        let result = documentStager.stage([record.fileURL])
        guard let url = result.urls.first, FileManager.default.isReadableFile(atPath: url.path) else {
            statusMessage = "File unavailable"
            return
        }

        let document = QueuedDocument(fileURL: url)
        queuedDocuments.append(document)
        selectedDocumentID = document.id
        statusMessage = ""
    }

    private func submitPrint(_ submittedDocuments: [QueuedDocument]) {
        guard !submittedDocuments.isEmpty, !isPrinting, selectedPrinterCanPrint else { return }

        resetPrintResultPresentation()
        isPrinting = true
        statusMessage = ""

        PrintBatchCoordinator.submit(
            submittedDocuments,
            printerID: printer,
            progress: { printProgress = $0 }
        ) { result in
            let resultsMatchSubmission = result.documentResults.count == submittedDocuments.count
                && zip(result.documentResults, submittedDocuments).allSatisfy { result, submitted in
                    result.fileURL == submitted.fileURL && result.requestedCopies == submitted.copies
                }
            let sentCopies = resultsMatchSubmission
                ? result.documentResults.map(\.submittedCopies)
                : []
            let completion = reducePrintQueueCompletion(
                submitted: submittedDocuments,
                currentQueue: queuedDocuments,
                submittedCopies: sentCopies
            )

            let visibleDocumentIDs = Set(queuedDocuments.map(\.id))
            let remainingDocumentIDs = Set(completion.remainingQueue.map(\.id))
            let shouldAnimateDocumentExit = completion.successfulDocuments.contains {
                visibleDocumentIDs.contains($0.id) && !remainingDocumentIDs.contains($0.id)
            }
            let finalStatusMessage = resultsMatchSubmission
                ? printStatusMessage(for: result)
                : "Failed"
            let presentation: PrintResultPresentation
            if resultsMatchSubmission && result.failed == 0 {
                presentation = .success
            } else {
                presentation = .failure(
                    partial: resultsMatchSubmission && result.submittedCopies > 0
                )
            }

            printHistory.recordSuccessfulPrints(
                completion.successfulDocuments.map(\.fileURL)
            )
            isPrinting = false
            printProgress = nil
            statusMessage = finalStatusMessage
            isClearingPrintResult = shouldAnimateDocumentExit

            if shouldAnimateDocumentExit {
                withAnimation(
                    reduceMotion
                        ? .linear(duration: 0.08)
                        : .easeOut(duration: prettyPrintDocumentExitDuration)
                ) {
                    queuedDocuments = completion.remainingQueue
                }
            } else {
                queuedDocuments = completion.remainingQueue
            }

            schedulePrintResultPresentation(
                presentation,
                finalStatusMessage: finalStatusMessage,
                waitsForDocumentExit: shouldAnimateDocumentExit
            )
        }
    }

    private func schedulePrintResultPresentation(
        _ presentation: PrintResultPresentation,
        finalStatusMessage: String,
        waitsForDocumentExit: Bool
    ) {
        printResultTask?.cancel()
        let shouldReduceMotion = reduceMotion
        let documentExitDelay: UInt64 = waitsForDocumentExit
            ? shouldReduceMotion ? 80_000_000 : 330_000_000
            : 0

        printResultTask = Task { @MainActor in
            if documentExitDelay > 0 {
                try? await Task.sleep(nanoseconds: documentExitDelay)
            }
            guard !Task.isCancelled else { return }

            withAnimation(
                shouldReduceMotion
                    ? .linear(duration: 0.08)
                    : .spring(response: 0.32, dampingFraction: 1)
            ) {
                isClearingPrintResult = false
                printResultPresentation = presentation
                statusMessage = ""
            }

            try? await Task.sleep(
                nanoseconds: UInt64(prettyPrintResultHoldDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }

            withAnimation(
                shouldReduceMotion
                    ? .linear(duration: 0.08)
                    : .easeOut(duration: 0.18)
            ) {
                printResultPresentation = nil
                statusMessage = presentation.isSuccess ? "" : finalStatusMessage
            }
            printResultTask = nil
        }
    }

    private func resetPrintResultPresentation() {
        printResultTask?.cancel()
        printResultTask = nil
        isClearingPrintResult = false
        printResultPresentation = nil
    }

    private func printStatusMessage(for result: PrintBatchResult) -> String {
        if result.failed == 0 {
            return result.requestedCopies == 1 ? "Sent" : "Sent \(result.submittedCopies) copies"
        }
        if result.submittedCopies == 0 {
            return "Failed"
        }
        return "Sent \(result.submittedCopies)/\(result.requestedCopies) copies; \(result.requestedCopies - result.submittedCopies) left"
    }
}

private struct PrettyPrintDocumentThumbnailItem: View {
    let document: QueuedDocument
    let isPrinting: Bool
    let isSelected: Bool
    let onSelect: (QueuedDocument.ID) -> Void
    let onPreview: (QueuedDocument.ID) -> Void
    let onRemove: (QueuedDocument.ID) -> Void
    let onCopiesChange: (QueuedDocument.ID, Int) -> Void

    @ObservedObject private var renameCoordinator = FileRenameCoordinator.shared
    @State private var isHovering = false

    private var fileName: String {
        renameCoordinator.displayName(for: document.originalFileURL)
    }

    private var selectOrRenameGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                onSelect(document.id)
                guard !isPrinting else { return }
                renameCoordinator.rename(document.originalFileURL, relativeTo: NSApp.keyWindow)
            }
            .exclusively(before: TapGesture().onEnded { onSelect(document.id) })
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .top) {
                FileThumbnailView(url: document.fileURL)
                    .background(PrettyPrintTileFill())
                    .id(document.fileURL)
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(isSelected ? 0.6 : 0), lineWidth: 1.5)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .gesture(selectOrRenameGesture)
                    .help("Double-click to rename")

                if isHovering {
                    HStack(spacing: 0) {
                        Button {
                            onPreview(document.id)
                        } label: {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(PrettyPrintThumbnailActionButtonStyle(tint: .blue))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                        .accessibilityLabel("Preview \(fileName)")
                        .help("Preview and arrange")
                        .prettyPrintButtonCursor()
                        .disabled(isPrinting)

                        Spacer(minLength: 0)

                        Button {
                            onRemove(document.id)
                        } label: {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(PrettyPrintThumbnailActionButtonStyle(tint: .red))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                        .accessibilityLabel("Remove \(fileName)")
                        .help("Remove \(fileName)")
                        .prettyPrintButtonCursor()
                        .disabled(isPrinting)
                    }
                    .frame(width: 68)
                    .transition(.identity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }

            Text(fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(width: 84)
                .contentShape(Rectangle())
                .gesture(selectOrRenameGesture)
                .help("Double-click to rename")

            PrettyPrintCopyStepper(
                copies: document.copies,
                isPrinting: isPrinting,
                onChange: { onCopiesChange(document.id, $0) }
            )
        }
        .frame(width: 90)
    }
}

private struct PrettyPrintCopyStepper: View {
    let copies: Int
    let isPrinting: Bool
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                guard copies > QueuedDocument.minimumCopies else { return }
                onChange(copies - 1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(
                PrettyPrintCopyStepperButtonStyle(
                    isAtLimit: isPrinting || copies <= QueuedDocument.minimumCopies
                )
            )
            .accessibilityLabel("Decrease copies")
            .help("Decrease copies")
            .prettyPrintButtonCursor()
            .disabled(isPrinting)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)

            Text("\(copies)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 26)
                .accessibilityLabel("\(copies) \(copies == 1 ? "copy" : "copies")")

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 1, height: 14)
                .accessibilityHidden(true)

            Button {
                guard copies < QueuedDocument.maximumCopies else { return }
                onChange(copies + 1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(
                PrettyPrintCopyStepperButtonStyle(
                    isAtLimit: isPrinting || copies >= QueuedDocument.maximumCopies
                )
            )
            .accessibilityLabel("Increase copies")
            .help("Increase copies")
            .prettyPrintButtonCursor()
            .disabled(isPrinting)
        }
        .padding(2)
        .frame(width: 84, height: 26)
        .background(
            PrettyPrintTileFill(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PrettyPrintCopyStepperButtonStyle: ButtonStyle {
    let isAtLimit: Bool

    func makeBody(configuration: Configuration) -> some View {
        PrettyPrintCopyStepperButton(
            configuration: configuration,
            isAtLimit: isAtLimit
        )
    }
}

private struct PrettyPrintCopyStepperButton: View {
    let configuration: ButtonStyle.Configuration
    let isAtLimit: Bool

    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(isAtLimit ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Color.accentColor.opacity(0.2)
                            : isHovering && !isAtLimit
                                ? Color.accentColor.opacity(0.1)
                                : .clear
                    )
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(prettyPrintHoverAnimation, value: isHovering)
    }
}

private struct PrettyPrintThumbnailActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        PrettyPrintThumbnailActionButton(configuration: configuration, tint: tint)
    }
}

private struct PrettyPrintFileDropButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrettyPrintFileDropButton(configuration: configuration)
    }
}

private struct PrettyPrintCheckingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots(activeIndex: nil)
            } else {
                PhaseAnimator([0, 1, 2]) { activeIndex in
                    dots(activeIndex: activeIndex)
                } animation: { _ in
                    .easeInOut(duration: 0.18)
                }
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }

    private func dots(activeIndex: Int?) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                let isActive = activeIndex == index

                Circle()
                    .fill(Color.secondary)
                    .frame(width: 3, height: 3)
                    .scaleEffect(activeIndex == nil ? 0.85 : isActive ? 1 : 0.72)
                    .opacity(activeIndex == nil ? 0.7 : isActive ? 1 : 0.35)
            }
        }
    }
}

private struct PrettyPrintFileDropButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(
                configuration.isPressed ? Color.primary : prettyPrintDropBlue.opacity(isHovering ? 1 : 0.85)
            )
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        prettyPrintDropBlue.opacity(
                            configuration.isPressed ? 0.22 : isHovering ? 0.14 : 0.07
                        )
                    )
            )
            .onHover { isHovering = $0 }
            .animation(prettyPrintHoverAnimation, value: isHovering)
    }
}

private struct PrettyPrintThumbnailActionButton: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.white)
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(tint)
                    .brightness(configuration.isPressed ? -0.18 : isHovering ? 0.1 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .onHover { isHovering = $0 }
            .animation(prettyPrintHoverAnimation, value: isHovering)
    }
}


private struct NavbarFileDropDelegate: DropDelegate {
    let onTargeted: (Int) -> Void
    let onExited: () -> Void
    let onPerform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        !providers(from: info).isEmpty
    }

    func dropEntered(info: DropInfo) {
        updateTarget(with: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(with: info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        onExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = providers(from: info)
        onExited()
        guard !providers.isEmpty else { return false }
        return onPerform(providers)
    }

    private func updateTarget(with info: DropInfo) {
        onTargeted(providers(from: info).count)
    }

    private func providers(from info: DropInfo) -> [NSItemProvider] {
        info.itemProviders(for: [.fileURL])
    }
}
