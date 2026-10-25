import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PrintComposerRequest {
    let documents: [QueuedDocument]
    let selectedDocumentID: QueuedDocument.ID?
    let paper: PrintPaper
    let printerID: String
    var startsFromBlankCanvas = false
}

struct PrintComposerResult {
    let documents: [QueuedDocument]
    let selectedDocumentID: QueuedDocument.ID?
    let originalDocumentIDs: Set<QueuedDocument.ID>
}

struct PrintComposerPageRequest {
    let document: QueuedDocument?
    let paper: PrintPaper
    let pageIndex: Int
    let composition: PrintComposition?
}

@MainActor
final class PrintComposerModel: ObservableObject {
    private static let nudgeStep: CGFloat = 1
    private static let largeNudgeStep: CGFloat = 10
    private static let duplicateOffset: CGFloat = 12
    private static let quarterTurn: Double = 90
    private static let itemPasteboardType = NSPasteboard.PasteboardType("io.github.landmann.prettyprint.composition-item")

    @Published var composition: PrintComposition?
    @Published private(set) var selectedItemIDs = Set<PrintCompositionItem.ID>()
    @Published private var groupRotation: Double = 0

    private var selectedItemID: PrintCompositionItem.ID? {
        get { selectedItemIDs.count == 1 ? selectedItemIDs.first : nil }
        set { setSelection(newValue.map { [$0] } ?? []) }
    }
    @Published private(set) var textFocusRequest: UUID?
    @Published var guides = PrintSnapGuides()
    @Published var isGridVisible = false {
        didSet { endInteraction() }
    }
    @Published var grid = PrintCompositionGrid() {
        didSet { endInteraction() }
    }
    @Published private(set) var sources: [URL: PrintSource] = [:]
    @Published private(set) var loadFailed = false
    @Published private(set) var pendingImports = 0
    @Published var errorMessage: String?

    let paper: PrintPaper
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAddFiles: (() -> Void)?

    private let request: PrintComposerPageRequest
    private let stager = PrettyPrintDocumentStager()
    private var initialComposition: PrintComposition?
    private var defaultComposition: PrintComposition?
    private var hasStartedLoading = false
    private var lastPasteboardChangeCount: Int?
    private var pasteCount = 0
    private var pendingTextHistory = Set<PrintCompositionItem.ID>()

    init(request: PrintComposerPageRequest, sources: [URL: PrintSource] = [:]) {
        self.request = request
        paper = request.paper
        self.sources = sources
    }

    var hasChanges: Bool { composition != initialComposition }
    var isDefault: Bool { composition == defaultComposition }

    var selectedItem: PrintCompositionItem? {
        guard let id = selectedItemID else { return nil }
        return composition?.items.first { $0.id == id }
    }

    var selectedItems: [PrintCompositionItem] {
        (composition?.items ?? []).filter { selectedItemIDs.contains($0.id) }
    }

    var selection: PrintCompositionSelection? {
        PrintCompositionSelection(items: selectedItems, rotation: groupRotation)
    }

    var selectionRotation: Double { selection?.rotation ?? 0 }

    var canReset: Bool {
        defaultComposition != nil
            && composition != defaultComposition
    }

    func load() async {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true

        if request.document == nil || request.document?.startedFromBlankCanvas == true {
            defaultComposition = PrintComposition(paper: paper, items: [])
        } else if let originalURL = request.document?.originalFileURL,
                  let source = await loadSource(originalURL) {
            defaultComposition = PrintComposition.single(
                sourceURL: originalURL,
                sourceAspect: source.aspect(request.pageIndex),
                paper: paper,
                pageIndex: request.pageIndex
            )
        }

        if let existing = request.composition {
            for url in Set(existing.items.compactMap(\.sourceURL)) {
                await loadSource(url)
            }
            let available = existing.items.filter { item in
                item.text != nil || item.sourceURL.flatMap { sources[$0] } != nil
            }
            guard available.count == existing.items.count else {
                loadFailed = true
                return
            }
            initialComposition = existing
            composition = PrintComposition(paper: existing.paper, items: available).adapted(to: paper)
        } else {
            guard let defaultComposition else {
                loadFailed = true
                return
            }
            initialComposition = defaultComposition
            composition = defaultComposition
        }
        selectedItemID = composition?.items.first?.id
    }


    func addText() {
        insertText(PrintText())
    }

    func addRecent(_ item: RecentLayoutItem) {
        switch item.content {
        case .file(let file):
            addFiles([file.resolvedURL])
        case .text(let text):
            insertText(text)
            RecentLayoutItemsStore.shared.rememberText(text)
        }
    }

    private func insertText(_ text: PrintText) {
        guard composition != nil else { return }
        finishTextEditing()
        let width = paper.size.width * 0.7
        let height = min(max(80, PrintTextDrawing.requiredHeight(text, width: width)), paper.size.height * 0.8)
        let size = CGSize(width: width, height: height)
        let item = PrintCompositionItem(
            content: .text(text),
            sourceAspect: size.width / size.height,
            frame: CGRect(x: (paper.size.width - size.width) / 2, y: (paper.size.height - size.height) / 2,
                          width: size.width, height: size.height),
            aspect: .free
        )
        composition?.items.append(item)
        selectedItemID = item.id
        errorMessage = nil
        editSelectedText()
    }

    func editSelectedText() {
        guard selectedItem?.text != nil else { return }
        textFocusRequest = UUID()
    }

    func setText(_ string: String, for id: PrintCompositionItem.ID) {
        updateText(id) { $0.string = string }
    }

    func setTextFont(_ font: PrintTextFont) {
        updateSelectedText { $0.font = font }
    }

    func setTextFontSize(_ size: CGFloat) {
        guard size.isFinite else { return }
        let range = PrintText.fontSizeRange
        updateSelectedText { $0.fontSize = min(max(size, range.lowerBound), range.upperBound) }
    }

    private func updateSelectedText(_ change: (inout PrintText) -> Void) {
        guard let id = selectedItemID else { return }
        updateText(id, change)
    }

    private func updateText(_ id: PrintCompositionItem.ID, _ change: (inout PrintText) -> Void) {
        update(id) { item in
            guard var text = item.text else { return }
            change(&text)
            guard text != item.text else { return }
            item.content = .text(text)
            pendingTextHistory.insert(id)
        }
    }

    func rememberPendingText() {
        for item in composition?.items ?? [] where pendingTextHistory.contains(item.id) {
            if let text = item.text { RecentLayoutItemsStore.shared.rememberText(text) }
        }
        pendingTextHistory.removeAll()
    }

    func finishTextEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        rememberPendingText()
    }

    private func remember(_ item: PrintCompositionItem) {
        if let url = item.sourceURL { RecentLayoutItemsStore.shared.rememberFile(url) }
        if let text = item.text {
            RecentLayoutItemsStore.shared.rememberText(text)
            pendingTextHistory.remove(item.id)
        }
    }

    func addFiles(_ urls: [URL]) {
        let staged = stager.stage(urls)
        if staged.failedCount > 0 {
            errorMessage = staged.failedCount == 1 ? "Couldn’t add 1 file" : "Couldn’t add \(staged.failedCount) files"
        }
        pendingImports += 1
        Task {
            defer { pendingImports -= 1 }
            for url in staged.urls {
                await addItem(for: url)
            }
        }
    }

    @discardableResult
    private func addItem(for url: URL) async -> Bool {
        guard composition != nil, let source = await loadSource(url) else {
            errorMessage = "Couldn’t open \(url.lastPathComponent)"
            return false
        }

        let cascade = CGFloat(composition?.items.count ?? 0) * Self.duplicateOffset
        let area = paper.bounds.insetBy(dx: paper.size.width * 0.2, dy: paper.size.height * 0.2)
        var frame = PrintCompositionGeometry.fitted(aspect: source.aspect(0), in: area)
        frame = frame.offsetBy(dx: cascade, dy: cascade)

        let item = PrintCompositionItem(content: .file(url), sourceAspect: source.aspect(0), frame: frame)
        finishTextEditing()
        textFocusRequest = nil
        composition?.items.append(item)
        selectedItemID = item.id
        errorMessage = nil
        return true
    }

    @discardableResult
    private func loadSource(_ url: URL) async -> PrintSource? {
        if let source = sources[url] {
            RecentLayoutItemsStore.shared.rememberFile(url)
            return source
        }
        let source = await PrintSource.load(url)
        if let source {
            sources[url] = source
            RecentLayoutItemsStore.shared.rememberFile(url)
        }
        return source
    }


    func select(_ id: PrintCompositionItem.ID?) {
        textFocusRequest = nil
        finishTextEditing()
        setSelection(id.map { [$0] } ?? [])
        if let item = selectedItem, let url = item.sourceURL {
            RecentLayoutItemsStore.shared.rememberFile(url)
        }
    }

    func setSelection(_ ids: Set<PrintCompositionItem.ID>) {
        guard ids != selectedItemIDs else { return }
        textFocusRequest = nil
        finishTextEditing()
        groupRotation = 0
        selectedItemIDs = ids
        endInteraction()
    }

    func select(_ id: PrintCompositionItem.ID, extending: Bool) {
        guard extending else { select(id); return }
        var ids = selectedItemIDs
        if !ids.insert(id).inserted { ids.remove(id) }
        setSelection(ids)
    }

    func selectAll() {
        setSelection(Set((composition?.items ?? []).map(\.id)))
    }

    func select(in rect: CGRect, addingTo base: Set<PrintCompositionItem.ID>) {
        let hits = (composition?.items ?? []).filter {
            PrintCompositionGeometry.boundingBox(of: $0.frame, rotation: $0.rotation).intersects(rect)
        }
        setSelection(base.union(hits.map(\.id)))
    }

    func renameSelected(relativeTo window: NSWindow?) {
        guard let url = selectedItem?.sourceURL else { return }
        FileRenameCoordinator.shared.rename(url, relativeTo: window)
    }

    private func selectAdjacent(_ direction: Int) {
        guard let items = composition?.items, !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedItemID } ?? (direction > 0 ? -1 : items.count)
        select(items[min(max(current + direction, 0), items.count - 1)].id)
    }

    func move(_ start: PrintCompositionSelection, by translation: CGSize, snapThreshold: CGFloat) {
        var proposed = start.frame.offsetBy(dx: translation.width, dy: translation.height)
        if isGridVisible, !PrettyPrintShortcuts.shared.bypassesSnapping(NSEvent.modifierFlags) {
            let snap = PrintCompositionGeometry.snapped(
                proposed, rotation: start.rotation, paper: paper.size,
                threshold: snapThreshold, grid: grid
            )
            proposed = snap.frame
            guides = snap.guides
        } else { endInteraction() }
        let dx = proposed.midX - start.frame.midX, dy = proposed.midY - start.frame.midY
        replaceItems(start.items.map { original in
            var item = original
            item.frame = item.frame.offsetBy(dx: dx, dy: dy)
            return item
        })
    }

    func resize(_ start: PrintCompositionSelection, corner: PrintCompositionCorner, to point: CGPoint, snapThreshold: CGFloat) {
        let proposed: CGRect
        if isGridVisible, !PrettyPrintShortcuts.shared.bypassesSnapping(NSEvent.modifierFlags) {
            let snap = PrintCompositionGeometry.snappedResize(
                start.frame, corner: corner, to: point, lockedRatio: start.lockedRatio,
                rotation: start.rotation, paper: paper.size, grid: grid, threshold: snapThreshold
            )
            proposed = snap.frame
            guides = snap.guides
        } else {
            proposed = PrintCompositionGeometry.resized(
                start.frame, corner: corner, to: point,
                lockedRatio: start.lockedRatio, rotation: start.rotation
            )
            endInteraction()
        }
        if start.items.count == 1 {
            update(start.items[0].id) { $0.frame = proposed }
        } else {
            replaceItems(start.transformed(to: proposed, rotation: start.rotation))
        }
    }

    private func replaceItems(_ items: [PrintCompositionItem]) {
        guard var composition else { return }
        let replacements = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        composition.items = composition.items.map { item in
            guard let replacement = replacements[item.id] else { return item }
            if replacement.text != item.text { pendingTextHistory.insert(item.id) }
            return replacement
        }
        self.composition = composition
    }

    func endInteraction() {
        guides = PrintSnapGuides()
    }

    func setAspect(_ aspect: PrintItemAspect) {
        guard let item = selectedItem, item.text == nil else { return }
        let id = item.id
        update(id) { item in
            item.aspect = aspect
            item.frame = PrintCompositionGeometry.applying(
                ratio: item.lockedRatio,
                to: item.frame,
                rotation: item.rotation,
                paper: paper.size
            )
        }
    }

    func setPage(_ pageIndex: Int) {
        guard let item = selectedItem, let url = item.sourceURL, let source = sources[url] else { return }
        let pageIndex = min(max(pageIndex, 0), source.pageCount - 1)
        update(item.id) { item in
            item.pageIndex = pageIndex
            item.sourceAspect = source.aspect(pageIndex)
            item.frame = PrintCompositionGeometry.applying(
                ratio: item.lockedRatio,
                to: item.frame,
                rotation: item.rotation,
                paper: paper.size
            )
        }
    }

    func fitSelectedToPage() {
        guard let selection else { return }
        if selection.items.count > 1 {
            let target = PrintCompositionGeometry.fitted(
                aspect: selection.frame.width / selection.frame.height,
                rotation: selection.rotation, in: paper.bounds
            )
            replaceItems(selection.transformed(to: target, rotation: selection.rotation))
            return
        }
        guard let id = selectedItemID else { return }
        update(id) { item in
            item.frame = PrintCompositionGeometry.fitted(
                aspect: item.lockedRatio ?? item.frame.width / item.frame.height,
                rotation: item.rotation,
                in: paper.bounds
            )
        }
    }

    func centerSelected() {
        guard let selection else { return }
        nudgeSelected(dx: paper.size.width / 2 - selection.frame.midX,
                      dy: paper.size.height / 2 - selection.frame.midY)
    }

    func duplicateSelected() {
        insertCopies(of: selectedItems, offset: Self.duplicateOffset)
    }

    func copySelected() {
        let items = selectedItems
        guard !items.isEmpty, let data = try? JSONEncoder().encode(items) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setData(data, forType: Self.itemPasteboardType) {
            errorMessage = "Couldn’t copy the selection"
        } else {
            items.forEach(remember)
        }
    }

    func paste() {
        guard composition != nil else { return }
        let pasteboard = NSPasteboard.general
        guard let data = pasteboard.data(forType: Self.itemPasteboardType) else { return }
        let decoder = JSONDecoder()
        let items = (try? decoder.decode([PrintCompositionItem].self, from: data))
            ?? (try? decoder.decode(PrintCompositionItem.self, from: data)).map { [$0] } ?? []
        guard !items.isEmpty, items.allSatisfy({ item in
            guard item.pageIndex >= 0, item.sourceAspect.isFinite, item.sourceAspect > 0,
                  item.frame.origin.x.isFinite, item.frame.origin.y.isFinite,
                  item.frame.width.isFinite, item.frame.width > 0,
                  item.frame.height.isFinite, item.frame.height > 0,
                  item.rotation.isFinite else { return false }
            switch item.content {
            case .file(let url): return url.isFileURL
            case .text(let text): return text.isValid
            }
        }) else { return }

        if lastPasteboardChangeCount != pasteboard.changeCount {
            lastPasteboardChangeCount = pasteboard.changeCount
            pasteCount = 0
        }
        pasteCount += 1
        let offset = Self.duplicateOffset * CGFloat(pasteCount)
        pendingImports += 1
        Task {
            defer { pendingImports -= 1 }
            for item in items {
                if let url = item.sourceURL {
                    guard let source = await loadSource(url), item.pageIndex < source.pageCount else {
                        errorMessage = "Couldn’t open the copied image"
                        return
                    }
                }
            }
            insertCopies(of: items, offset: offset)
        }
    }

    private func insertCopies(of items: [PrintCompositionItem], offset: CGFloat) {
        guard !items.isEmpty else { return }
        finishTextEditing()
        textFocusRequest = nil
        let copies = items.map { item in
            PrintCompositionItem(
                content: item.content, pageIndex: item.pageIndex, sourceAspect: item.sourceAspect,
                frame: item.frame.offsetBy(dx: 0, dy: offset), aspect: item.aspect, rotation: item.rotation
            )
        }
        composition?.items.append(contentsOf: copies)
        setSelection(Set(copies.map(\.id)))
        copies.forEach(remember)
        errorMessage = nil
    }

    func setRotation(_ degrees: Double) {
        guard degrees.isFinite, let selection else { return }
        let rotation = PrintCompositionGeometry.normalized(degrees: degrees)
        replaceItems(selection.transformed(to: selection.frame, rotation: rotation))
        if selection.items.count > 1 { groupRotation = rotation }
    }

    func rotateSelected(clockwise: Bool) {
        guard selection != nil else { return }
        let quarters = selectionRotation / Self.quarterTurn
        let next = clockwise ? (quarters + 0.0001).rounded(.up) : (quarters - 0.0001).rounded(.down)
        setRotation(next * Self.quarterTurn)
    }

    func reset() {
        guard let defaultComposition else { return }
        finishTextEditing()
        textFocusRequest = nil
        composition = defaultComposition
        selectedItemID = defaultComposition.items.first?.id
        errorMessage = nil
    }

    func removeSelected() {
        guard !selectedItemIDs.isEmpty else { return }
        finishTextEditing()
        textFocusRequest = nil
        composition?.items.removeAll { selectedItemIDs.contains($0.id) }
        setSelection([])
    }

    private func nudgeSelected(dx: CGFloat, dy: CGFloat) {
        replaceItems(selectedItems.map { original in
            var item = original
            item.frame = item.frame.offsetBy(dx: dx, dy: dy)
            return item
        })
    }

    private func update(_ id: PrintCompositionItem.ID, _ change: (inout PrintCompositionItem) -> Void) {
        guard let index = composition?.items.firstIndex(where: { $0.id == id }) else { return }
        change(&composition!.items[index])
    }


    func cancel() {
        finishTextEditing()
        onCancel?()
    }

    func done() {
        finishTextEditing()
        onDone?()
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              NSApp.modalWindow == nil, !(window.firstResponder is NSTextView),
              let press = PrettyPrintKeyPress(event),
              let action = PrettyPrintShortcuts.shared.action(for: press, in: .editor) else { return false }
        switch action {
        case .settings: PrettyPrintSettingsPresenter.shared.show(relativeTo: window)
        case .addFiles: onAddFiles?()
        case .addText: addText()
        case .editText: editSelectedText()
        case .textFont:
            if let text = selectedItem?.text, let index = PrintTextFont.allCases.firstIndex(of: text.font) {
                setTextFont(PrintTextFont.allCases[(index + 1) % PrintTextFont.allCases.count])
            }
        case .largerText: if let text = selectedItem?.text { setTextFontSize(text.fontSize + 1) }
        case .smallerText: if let text = selectedItem?.text { setTextFontSize(text.fontSize - 1) }
        case .rename: renameSelected(relativeTo: window)
        case .selectAll: selectAll()
        case .copy: copySelected()
        case .paste: paste()
        case .duplicate: duplicateSelected()
        case .removeImage: removeSelected()
        case .fit: fitSelectedToPage()
        case .center: centerSelected()
        case .reset: reset()
        case .done: done()
        case .cancel: cancel()
        case .deselect:
            if !selectedItemIDs.isEmpty { select(nil) } else { cancel() }
        case .previousImage: selectAdjacent(-1)
        case .nextImage: selectAdjacent(1)
        case .aspect:
            if let item = selectedItem, let index = PrintItemAspect.allCases.firstIndex(of: item.aspect) {
                setAspect(PrintItemAspect.allCases[(index + 1) % PrintItemAspect.allCases.count])
            }
        case .rotateLeft: rotateSelected(clockwise: false)
        case .rotateRight: rotateSelected(clockwise: true)
        case .previousPage: if let item = selectedItem { setPage(item.pageIndex - 1) }
        case .nextPage: if let item = selectedItem { setPage(item.pageIndex + 1) }
        case .grid: if composition != nil { isGridVisible.toggle() }
        case .moreHorizontal, .fewerHorizontal, .moreVertical, .fewerVertical:
            guard isGridVisible else { return true }
            let range = PrintCompositionGrid.lineCountRange
            switch action {
            case .moreHorizontal: grid.horizontalLineCount = min(grid.horizontalLineCount + 1, range.upperBound)
            case .fewerHorizontal: grid.horizontalLineCount = max(grid.horizontalLineCount - 1, range.lowerBound)
            case .moreVertical: grid.verticalLineCount = min(grid.verticalLineCount + 1, range.upperBound)
            case .fewerVertical: grid.verticalLineCount = max(grid.verticalLineCount - 1, range.lowerBound)
            default: break
            }
        case .moveLeft: nudgeSelected(dx: -Self.nudgeStep, dy: 0)
        case .moveRight: nudgeSelected(dx: Self.nudgeStep, dy: 0)
        case .moveUp: nudgeSelected(dx: 0, dy: -Self.nudgeStep)
        case .moveDown: nudgeSelected(dx: 0, dy: Self.nudgeStep)
        case .moveLeftFast: nudgeSelected(dx: -Self.largeNudgeStep, dy: 0)
        case .moveRightFast: nudgeSelected(dx: Self.largeNudgeStep, dy: 0)
        case .moveUpFast: nudgeSelected(dx: 0, dy: -Self.largeNudgeStep)
        case .moveDownFast: nudgeSelected(dx: 0, dy: Self.largeNudgeStep)
        default: return false
        }
        return true
    }
}


private final class PrintComposerWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false
    }
}

@MainActor
final class PrintComposerPresenter {
    private var window: NSWindow?
    private var keyMonitor: Any?

    func present(_ request: PrintComposerRequest, onFinish: @escaping (PrintComposerResult?) -> Void) {
        guard window == nil,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            onFinish(nil)
            return
        }

        let session = PrintComposerSession(request: request)
        let visibleFrame = screen.visibleFrame
        let window = PrintComposerWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: visibleFrame.width - 48,
                height: visibleFrame.height - 72
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit layout"
        window.contentMinSize = NSSize(
            width: min(900, visibleFrame.width - 48),
            height: min(620, visibleFrame.height - 72)
        )
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = window
        window.onClose = { [weak session] in session?.cancel() }
        window.contentView = NSHostingView(rootView: PrintComposerSessionView(session: session))
        window.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.midY - window.frame.height / 2
        ))

        session.onFinish = { [weak self, weak session] result in
            session?.onFinish = nil
            self?.dismiss()
            onFinish(result)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak window, weak session] event in
            guard let window, event.window === window, let session else {
                return event
            }
            if event.type == .flagsChanged {
                if PrettyPrintShortcuts.shared.bypassesSnapping(event.modifierFlags) {
                    session.activePage?.endInteraction()
                }
                return event
            }
            return session.handleKeyDown(event) ? nil : event
        }

        self.window = window
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            window.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil

        guard let window else { return }
        self.window = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }
}


private let composerAccent = Color.accentColor
private let composerGuideColor = Color(red: 1, green: 0.2, blue: 0.55)

struct PrintComposerGridControls: View {
    @ObservedObject var model: PrintComposerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.isGridVisible) {
                ComposerActionLabel("View Gridline", systemImage: "grid")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
            .composerLargeButton(.accent)
            .help("Snap images to the grid while moving or resizing.")

            if model.isGridVisible {
                HStack(spacing: 12) {
                    Stepper(value: $model.grid.horizontalLineCount, in: PrintCompositionGrid.lineCountRange) {
                        Text("Horizontal: \(model.grid.horizontalLineCount)").monospacedDigit().fixedSize()
                    }
                    .accessibilityLabel("Horizontal gridlines")
                    .accessibilityValue("\(model.grid.horizontalLineCount)")

                    Stepper(value: $model.grid.verticalLineCount, in: PrintCompositionGrid.lineCountRange) {
                        Text("Vertical: \(model.grid.verticalLineCount)").monospacedDigit().fixedSize()
                    }
                    .accessibilityLabel("Vertical gridlines")
                    .accessibilityValue("\(model.grid.verticalLineCount)")
                }
                .controlSize(.small)
                .font(.caption)
            }
        }
        .font(.callout)
        .disabled(model.composition == nil)
    }
}

struct PrintComposerCanvas: View {
    private static let handleSize: CGFloat = 10
    private static let handleHitSize: CGFloat = 22
    private static let snapDistance: CGFloat = 6

    @ObservedObject var model: PrintComposerModel
    @State private var dragStart: (id: PrintCompositionItem.ID, selection: PrintCompositionSelection?)?
    @State private var resizeStart: (corner: PrintCompositionCorner, selection: PrintCompositionSelection)?
    @State private var marqueeStart: Set<PrintCompositionItem.ID>?
    @State private var marquee: CGRect?
    var isActive = true
    var onActivate: () -> Void = {}

    var body: some View {
        GeometryReader { geometry in
            let pageSize = model.paper.fittedSize(
                in: CGSize(
                    width: max(1, geometry.size.width - PrintPageRulers.canvasInsets.width),
                    height: max(1, geometry.size.height - PrintPageRulers.canvasInsets.height)
                )
            )
            let scale = pageSize.width / model.paper.size.width

            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(nil) }

                page(size: pageSize, scale: scale)
                    .offset(x: PrintPageRulers.canvasInsets.width / 2)
                PrintPageRulers(paper: model.paper, pageSize: pageSize)
                    .offset(y: -(PrintPageRulers.thickness + PrintPageRulers.gap) / 2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in onActivate() })
    }

    @ViewBuilder
    private func page(size: CGSize, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.white)

                if let composition = model.composition {
                    ForEach(composition.items) { item in
                        itemContent(item, scale: scale)
                    }
                } else if model.loadFailed {
                    Text("Couldn’t open this file")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: size.width, height: size.height)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)

            if isActive && model.isGridVisible {
                gridLines(size: size, scale: scale)
            }

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("page"))
                        .onChanged { value in
                            if marqueeStart == nil {
                                marqueeStart = NSEvent.modifierFlags.contains(.shift) ? model.selectedItemIDs : []
                                model.setSelection(marqueeStart ?? [])
                            }
                            let rect = CGRect(
                                x: min(value.startLocation.x, value.location.x) / scale,
                                y: min(value.startLocation.y, value.location.y) / scale,
                                width: abs(value.translation.width) / scale,
                                height: abs(value.translation.height) / scale
                            )
                            guard abs(value.translation.width) + abs(value.translation.height) > 3 else { return }
                            marquee = rect
                            model.select(in: rect, addingTo: marqueeStart ?? [])
                        }
                        .onEnded { _ in
                            marqueeStart = nil
                            marquee = nil
                        }
                )

            if let composition = model.composition {
                ForEach(composition.items) { item in
                    itemHitArea(item, scale: scale)
                }

                if isActive && model.selectedItemIDs.count > 1 {
                    ForEach(model.selectedItems) { item in
                        let frame = scaled(item.frame, by: scale)
                        Rectangle()
                            .strokeBorder(composerAccent.opacity(0.6), lineWidth: 1)
                            .frame(width: frame.width, height: frame.height)
                            .rotationEffect(.degrees(item.rotation))
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                    }
                }
                if isActive, let selection = model.selection {
                    selectionOutline(selection, scale: scale)
                }
                if isActive, let marquee {
                    let frame = scaled(marquee, by: scale)
                    Rectangle()
                        .fill(composerAccent.opacity(0.12))
                        .overlay { Rectangle().strokeBorder(composerAccent, lineWidth: 1) }
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                }

                if isActive { guideLines(size: size, scale: scale) }
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "page")
    }

    private func itemContent(_ item: PrintCompositionItem, scale: CGFloat) -> some View {
        let frame = scaled(item.frame, by: scale)

        return Group {
            if let text = item.text {
                ComposerTextPreview(text: text, scale: scale)
            } else if let url = item.sourceURL, let source = model.sources[url] {
                Image(nsImage: source.previewImage(item.pageIndex))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipped()
        .rotationEffect(.degrees(item.rotation))
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
    }

    private func itemHitArea(_ item: PrintCompositionItem, scale: CGFloat) -> some View {
        let frame = scaled(item.frame, by: scale)

        return Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: frame.width, height: frame.height)
            .rotationEffect(.degrees(item.rotation))
            .position(x: frame.midX, y: frame.midY)
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.openHand.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("page"))
                    .onChanged { value in
                        if dragStart?.id != item.id {
                            model.finishTextEditing()
                            if NSEvent.modifierFlags.contains(.shift) {
                                model.select(item.id, extending: true)
                            } else if !model.selectedItemIDs.contains(item.id) {
                                model.select(item.id)
                            }
                            dragStart = (item.id, model.selectedItemIDs.contains(item.id) ? model.selection : nil)
                            NSCursor.closedHand.set()
                            if value.translation == .zero { return }
                        }
                        guard let start = dragStart?.selection, value.translation != .zero else { return }
                        model.move(
                            start,
                            by: CGSize(
                                width: value.translation.width / scale,
                                height: value.translation.height / scale
                            ),
                            snapThreshold: Self.snapDistance / scale
                        )
                    }
                    .onEnded { _ in
                        dragStart = nil
                        model.endInteraction()
                        NSCursor.openHand.set()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard item.text != nil else { return }
                model.select(item.id)
                model.editSelectedText()
            })
    }

    private func selectionOutline(_ selection: PrintCompositionSelection, scale: CGFloat) -> some View {
        let frame = scaled(selection.frame, by: scale)

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(composerAccent, lineWidth: 1.5)
                .frame(width: frame.width, height: frame.height)
                .rotationEffect(.degrees(selection.rotation))
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)

            ForEach(PrintCompositionCorner.allCases) { corner in
                let point = PrintCompositionGeometry.corner(corner, of: frame, rotation: selection.rotation)

                ZStack {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: Self.handleSize, height: Self.handleSize)
                        .overlay {
                            Rectangle().strokeBorder(composerAccent, lineWidth: 1.5)
                        }
                        .rotationEffect(.degrees(selection.rotation))
                }
                .frame(width: Self.handleHitSize, height: Self.handleHitSize)
                .contentShape(Rectangle())
                .position(point)
                .onContinuousHover { phase in
                    switch phase {
                    case .active: NSCursor.crosshair.set()
                    case .ended: NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("page"))
                        .onChanged { value in
                            if resizeStart == nil {
                                model.finishTextEditing()
                                resizeStart = (corner, model.selection ?? selection)
                            }
                            guard let start = resizeStart, value.translation != .zero else { return }
                            let origin = PrintCompositionGeometry.corner(
                                start.corner, of: start.selection.frame, rotation: start.selection.rotation
                            )
                            model.resize(
                                start.selection,
                                corner: start.corner,
                                to: CGPoint(x: origin.x + value.translation.width / scale,
                                            y: origin.y + value.translation.height / scale),
                                snapThreshold: Self.snapDistance / scale
                            )
                        }
                        .onEnded { _ in
                            resizeStart = nil
                            model.endInteraction()
                        }
                )
                .accessibilityLabel("Resize")
            }
        }
    }

    private func gridLines(size: CGSize, scale: CGFloat) -> some View {
        Path { path in
            for x in model.grid.verticalLines(in: model.paper.size) {
                path.move(to: CGPoint(x: x * scale, y: 0))
                path.addLine(to: CGPoint(x: x * scale, y: size.height))
            }
            for y in model.grid.horizontalLines(in: model.paper.size) {
                path.move(to: CGPoint(x: 0, y: y * scale))
                path.addLine(to: CGPoint(x: size.width, y: y * scale))
            }
        }
        .stroke(Color.blue.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func guideLines(size: CGSize, scale: CGFloat) -> some View {
        if let x = model.guides.vertical {
            Rectangle()
                .fill(composerGuideColor)
                .frame(width: 1, height: size.height)
                .position(x: x * scale, y: size.height / 2)
                .allowsHitTesting(false)
        }
        if let y = model.guides.horizontal {
            Rectangle()
                .fill(composerGuideColor)
                .frame(width: size.width, height: 1)
                .position(x: size.width / 2, y: y * scale)
                .allowsHitTesting(false)
        }
    }

    private func scaled(_ rect: CGRect, by scale: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }
}

struct PrintComposerInspector: View {
    @ObservedObject var model: PrintComposerModel
    @ObservedObject private var fileNames = FileRenameCoordinator.shared

    var body: some View {
        GeometryReader { geometry in
            let hasSelection = !model.selectedItemIDs.isEmpty
            let panelHeight = hasSelection ? min(150, geometry.size.height * 0.27) : (geometry.size.height - 1) / 2
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Layers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    ScrollView {
                        if model.composition?.items.isEmpty ?? true {
                            Text("No layers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                        } else { itemList }
                    }
                }
                .frame(height: panelHeight)
                Divider()
                RecentLayoutItemsView(onSelect: model.addRecent)
                    .frame(height: panelHeight)
                if hasSelection {
                    Divider()
                    ScrollView {
                        if let item = model.selectedItem {
                            itemControls(item)
                        } else { groupControls }
                    }
                }
            }
        }
    }

    private func itemTitle(_ item: PrintCompositionItem) -> String {
        if let text = item.text { return text.title }
        return item.sourceURL.map { fileNames.displayName(for: $0) } ?? "File"
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array((model.composition?.items ?? []).enumerated()), id: \.element.id) { index, item in
                let isSelected = model.selectedItemIDs.contains(item.id)

                Button {
                    model.select(item.id, extending: NSEvent.modifierFlags.contains(.shift))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.text == nil ? "doc" : "textformat")
                            .foregroundStyle(isSelected ? Color.white : .secondary)
                            .accessibilityHidden(true)
                        Text(itemTitle(item))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .foregroundStyle(isSelected ? Color.white : .primary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .prettyPrintHoverHighlight(.selection)
                .prettyPrintButtonCursor()
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    model.select(item.id)
                    if item.text != nil { model.editSelectedText() }
                    else { model.renameSelected(relativeTo: NSApp.keyWindow) }
                })
                .help(item.text == nil ? "Shift-click to select several layers. Double-click to rename the original file." : "Shift-click to select several layers. Double-click to edit text.")
                .accessibilityLabel("Item \(index + 1), \(itemTitle(item))")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private func itemControls(_ item: PrintCompositionItem) -> some View {
        let pageCount = item.sourceURL.flatMap { model.sources[$0]?.pageCount } ?? 1

        return VStack(alignment: .leading, spacing: 14) {
            if let text = item.text {
                textControls(text, item: item)
            } else {
                LabeledContent("Aspect ratio") {
                    Picker(
                        "Aspect ratio",
                        selection: Binding(
                            get: { item.aspect },
                            set: { model.setAspect($0) }
                        )
                    ) {
                        ForEach(PrintItemAspect.allCases) { aspect in
                            Text(aspect.title).tag(aspect)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .prettyPrintButtonCursor()
                    .help("Image aspect ratio")
                }
            }

            rotationControls

            LabeledContent("Size") {
                Text(model.paper.formattedSize(item.frame.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if pageCount > 1 {
                LabeledContent("Source page") {
                    Stepper(
                        "\(item.pageIndex + 1) of \(pageCount)",
                        value: Binding(
                            get: { item.pageIndex },
                            set: { model.setPage($0) }
                        ),
                        in: 0...(pageCount - 1)
                    )
                    .monospacedDigit()
                }
            }

            selectionActions
        }
        .font(.callout)
        .padding(12)
    }

    private var groupControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(model.selectedItemIDs.count) layers selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            rotationControls
            if let selection = model.selection {
                LabeledContent("Size") {
                    Text(model.paper.formattedSize(selection.frame.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            selectionActions
        }
        .font(.callout)
        .padding(12)
    }

    private var rotationControls: some View {
        LabeledContent("Rotation") {
            HStack(spacing: 10) {
                PrintComposerRotationDial(degrees: model.selectionRotation, onChange: model.setRotation)

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 2) {
                        TextField(
                            "Degrees",
                            value: Binding(
                                get: { model.selectionRotation.rounded() },
                                set: { model.setRotation($0) }
                            ),
                            format: .number.precision(.fractionLength(0))
                        )
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 44)
                        Text("°")
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        rotateButton(clockwise: false)
                        rotateButton(clockwise: true)
                    }
                }
            }
        }
    }

    private var selectionActions: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                inspectorButton("Fit to page", systemImage: "arrow.up.left.and.arrow.down.right", action: model.fitSelectedToPage)
                inspectorButton("Center", systemImage: "align.horizontal.center", action: model.centerSelected)
            }
            GridRow {
                inspectorButton("Duplicate", systemImage: "plus.square.on.square", action: model.duplicateSelected)
                    .help("Duplicate the selection slightly below the original.")
                inspectorButton("Remove", systemImage: "trash", role: .destructive, action: model.removeSelected)
            }
        }
    }

    private func textControls(_ text: PrintText, item: PrintCompositionItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ComposerTextEditor(
                text: Binding(
                    get: { model.composition?.items.first { $0.id == item.id }?.text?.string ?? "" },
                    set: { model.setText($0, for: item.id) }
                ),
                focusRequest: model.textFocusRequest,
                onEndEditing: model.rememberPendingText
            )
            .id(item.id)
            .frame(height: ComposerTextEditor.height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)) }

            LabeledContent("Font") {
                Picker("Font", selection: Binding(get: { text.font }, set: model.setTextFont)) {
                    ForEach(PrintTextFont.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                .labelsHidden()
                .prettyPrintButtonCursor()
            }

            LabeledContent("Font size") {
                HStack(spacing: 6) {
                    TextField("Font size", value: Binding(
                        get: { Double(text.fontSize) },
                        set: { model.setTextFontSize(CGFloat($0)) }
                    ),
                              format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                    Text("pt").foregroundStyle(.secondary)
                    Stepper("Font size", value: Binding(get: { text.fontSize }, set: model.setTextFontSize),
                            in: PrintText.fontSizeRange, step: 1)
                        .labelsHidden()
                        .prettyPrintButtonCursor()
                }
            }

            if PrintTextDrawing.requiredHeight(text, width: item.frame.width) > item.frame.height + 0.5 {
                Text("Some text is outside the box. Resize it or use a smaller font size.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func rotateButton(clockwise: Bool) -> some View {
        Button {
            model.rotateSelected(clockwise: clockwise)
        } label: {
            Image(systemName: clockwise ? "rotate.right" : "rotate.left")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.roundedRectangle(radius: 5))
        .prettyPrintHoverHighlight(.accent, cornerRadius: 5)
        .prettyPrintButtonCursor()
        .accessibilityLabel(clockwise ? "Rotate right 90°" : "Rotate left 90°")
        .help(clockwise ? "Rotate right 90°" : "Rotate left 90°")
    }

    private func inspectorButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            ComposerActionLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 6))
        .tint(role == .destructive ? .red : nil)
        .prettyPrintHoverHighlight(role == .destructive ? .destructive : .accent)
        .prettyPrintButtonCursor()
    }
}

struct ComposerActionLabel: View {
    let title: String
    let systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PrintComposerRotationDial: View {
    private static let size: CGFloat = 52
    private static let fineSnap: Double = 15
    private static let quarterSnapTolerance: Double = 4

    let degrees: Double
    let onChange: (Double) -> Void

    @State private var isDragging = false
    @State private var isHovering = false

    var body: some View {
        let radius = Self.size / 2

        ZStack {
            Circle()
                .fill(Color.primary.opacity(isDragging ? 0.12 : isHovering ? 0.09 : 0.06))
            Circle()
                .strokeBorder(Color.primary.opacity(isDragging ? 0.35 : 0.18), lineWidth: 1)

            ForEach(0..<4, id: \.self) { quarter in
                Capsule()
                    .fill(Color.primary.opacity(0.3))
                    .frame(width: 1.5, height: 5)
                    .offset(y: -radius + 6)
                    .rotationEffect(.degrees(Double(quarter) * 90))
            }

            Capsule()
                .fill(composerAccent)
                .frame(width: 2, height: radius - 9)
                .offset(y: -(radius - 9) / 2)
                .rotationEffect(.degrees(degrees))

            Circle()
                .fill(composerAccent)
                .frame(width: 6, height: 6)
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .onHover { isHovering = $0 }
        .animation(prettyPrintHoverAnimation, value: isHovering)
        .animation(prettyPrintHoverAnimation, value: isDragging)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    let dx = value.location.x - radius
                    let dy = value.location.y - radius
                    guard (dx * dx + dy * dy).squareRoot() > 4 else { return }
                    onChange(snapped(atan2(dx, -dy) * 180 / .pi))
                }
                .onEnded { _ in isDragging = false }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
        .prettyPrintButtonCursor()
        .help("Drag to rotate; double-click to reset.")
        .accessibilityElement()
        .accessibilityLabel("Rotation")
        .accessibilityValue("\(Int(degrees.rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(degrees + 1)
            case .decrement: onChange(degrees - 1)
            @unknown default: break
            }
        }
    }

    private func snapped(_ angle: Double) -> Double {
        if PrettyPrintShortcuts.shared.usesRotationSteps(NSEvent.modifierFlags) {
            return (angle / Self.fineSnap).rounded() * Self.fineSnap
        }
        let quarter = (angle / 90).rounded() * 90
        return abs(angle - quarter) < Self.quarterSnapTolerance ? quarter : angle.rounded()
    }
}


extension View {
    func composerLargeButton(_ tone: PrettyPrintHoverTone) -> some View {
        controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: composerLargeButtonRadius))
            .prettyPrintHoverHighlight(tone, cornerRadius: composerLargeButtonRadius)
            .prettyPrintButtonCursor()
    }
}

private let composerLargeButtonRadius: CGFloat = 8
