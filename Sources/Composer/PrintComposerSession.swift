import AppKit
import Combine
import SwiftUI

@MainActor
final class PrintComposerDocument: ObservableObject, Identifiable {
    let id: UUID
    let original: QueuedDocument?
    @Published private(set) var pages: [PrintComposerModel] = []
    @Published var selectedPageIndex = 0
    @Published var sides: PrintSides
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false
    private var pageSubscriptions: [AnyCancellable] = []
    private var hasLoaded = false

    init(document: QueuedDocument?) {
        id = document?.id ?? UUID()
        original = document
        sides = document?.sides ?? .oneSided
    }

    var title: String {
        if original?.startedFromBlankCanvas == true { return "Blank canvas" }
        return original.map { FileRenameCoordinator.shared.displayName(for: $0.originalFileURL) } ?? "Blank canvas"
    }

    var activePage: PrintComposerModel? {
        pages.indices.contains(selectedPageIndex) ? pages[selectedPageIndex] : nil
    }

    var canFinish: Bool {
        guard !isLoading else { return false }
        if loadFailed { return original != nil }
        guard hasLoaded else { return original != nil }
        guard !pages.isEmpty, pages.allSatisfy({ $0.composition != nil && !$0.loadFailed && $0.pendingImports == 0 }) else { return false }
        return true
    }

    func load(paper: PrintPaper, configure: (PrintComposerModel) -> Void) async {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        var sources: [URL: PrintSource] = [:]
        if let url = original?.originalFileURL, let source = await PrintSource.load(url) {
            sources[url] = source
        }
        let count = original?.layoutPages?.count
            ?? original.flatMap { sources[$0.originalFileURL]?.pageCount }
            ?? 1
        var loaded: [PrintComposerModel] = []
        for index in 0..<count {
            let page = PrintComposerModel(request: PrintComposerPageRequest(
                document: original,
                paper: paper,
                pageIndex: index,
                composition: original?.layoutPages?[index]
            ), sources: sources)
            await page.load()
            sources.merge(page.sources) { _, new in new }
            configure(page)
            loaded.append(page)
        }
        pages = loaded
        loadFailed = loaded.isEmpty || loaded.contains { $0.loadFailed }
        hasLoaded = !loadFailed
        pageSubscriptions = pages.map { page in
            page.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    func finishTextEditing() {
        activePage?.finishTextEditing()
    }
}

@MainActor
final class PrintComposerSession: ObservableObject {
    @Published private(set) var documents: [PrintComposerDocument]
    @Published private(set) var selectedDocumentID: UUID?
    @Published private(set) var supportedSides: [PrintSides]?
    @Published var errorMessage: String?
    @Published private(set) var scrollRequest: UUID?
    @Published private(set) var pendingDocumentImports = 0
    let paper: PrintPaper
    let printerID: String
    var onFinish: ((PrintComposerResult?) -> Void)?
    private let originalDocumentIDs: Set<QueuedDocument.ID>
    private let stager = PrettyPrintDocumentStager()
    private var subscriptions: [AnyCancellable] = []

    init(request: PrintComposerRequest) {
        paper = request.paper
        printerID = request.printerID
        originalDocumentIDs = Set(request.documents.map(\.id))
        documents = request.documents.map { PrintComposerDocument(document: $0) }
        if request.startsFromBlankCanvas {
            let blank = PrintComposerDocument(document: nil)
            documents.append(blank)
            selectedDocumentID = blank.id
        } else {
            selectedDocumentID = request.selectedDocumentID ?? documents.first?.id
        }
        observeDocuments()
    }

    var selectedDocument: PrintComposerDocument? {
        documents.first { $0.id == selectedDocumentID }
    }

    var activePage: PrintComposerModel? { selectedDocument?.activePage }

    var canGoToPreviousPage: Bool { adjacentPage(offset: -1) != nil }
    var canGoToNextPage: Bool { adjacentPage(offset: 1) != nil }

    var canFinish: Bool {
        pendingDocumentImports == 0 && documents.allSatisfy {
            $0.canFinish && ($0.sides == .oneSided || supportedSides?.contains($0.sides) == true)
        }
    }

    func loadCapabilities() async {
        supportedSides = await PrinterDirectory.capabilities(for: printerID).sides
    }

    func loadSelectedDocument() async {
        guard let document = selectedDocument else { return }
        await loadDocument(document)
        guard !Task.isCancelled,
              let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let neighbors = [index - 1, index + 1].compactMap { documents.indices.contains($0) ? documents[$0] : nil }
        for neighbor in neighbors {
            guard !Task.isCancelled else { return }
            await loadDocument(neighbor)
        }
    }

    func loadDocument(_ document: PrintComposerDocument) async {
        let paper = paper
        await Task { @MainActor [weak self] in
            await document.load(paper: paper) { page in
                page.onDone = { [weak self] in self?.done() }
                page.onCancel = { [weak self] in self?.cancel() }
                page.onAddFiles = { [weak self] in self?.chooseFiles() }
            }
        }.value
    }

    func selectDocument(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        activateDocument(id)
        scrollRequest = UUID()
    }

    private func activateDocument(_ id: UUID) {
        guard id != selectedDocumentID, documents.contains(where: { $0.id == id }) else { return }
        selectedDocument?.finishTextEditing()
        selectedDocumentID = id
        errorMessage = nil
    }

    func selectPage(_ index: Int, in document: PrintComposerDocument) {
        guard documents.contains(where: { $0.id == document.id }),
              document.pages.indices.contains(index) || (index == 0 && document.pages.isEmpty) else { return }
        activateDocument(document.id)
        guard document.selectedPageIndex != index else { return }
        document.finishTextEditing()
        document.selectedPageIndex = index
    }

    func movePage(offset: Int) {
        guard let target = adjacentPage(offset: offset) else { return }
        selectPage(target.index, in: target.document)
        scrollRequest = UUID()
    }

    private func adjacentPage(offset: Int) -> (document: PrintComposerDocument, index: Int)? {
        guard let document = selectedDocument,
              !document.pages.isEmpty || document.loadFailed,
              let documentIndex = documents.firstIndex(where: { $0.id == document.id }) else { return nil }
        let pageCount = document.loadFailed ? 1 : document.pages.count
        let pageIndex = document.selectedPageIndex + offset
        if (0..<pageCount).contains(pageIndex) { return (document, pageIndex) }
        let nextDocumentIndex = documentIndex + offset
        guard documents.indices.contains(nextDocumentIndex) else { return nil }
        let nextDocument = documents[nextDocumentIndex]
        if offset > 0 { return (nextDocument, 0) }
        guard !nextDocument.pages.isEmpty || nextDocument.loadFailed else { return nil }
        return (nextDocument, nextDocument.loadFailed ? 0 : nextDocument.pages.count - 1)
    }

    func removeDocument(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].finishTextEditing()
        documents.remove(at: index)
        if selectedDocumentID == id {
            selectedDocumentID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
            scrollRequest = UUID()
        }
        observeDocuments()
        errorMessage = nil
    }

    func chooseFiles() {
        chooseFiles { addFiles($0) }
    }

    func choosePageFiles() {
        guard let page = activePage else { return }
        chooseFiles { page.addFiles($0) }
    }

    private func chooseFiles(onChoose: ([URL]) -> Void) {
        selectedDocument?.finishTextEditing()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        let window = NSApp.keyWindow
        let level = window?.level
        window?.level = .normal
        let response = panel.runModal()
        if let level {
            window?.level = level
            window?.makeKeyAndOrderFront(nil)
        }
        guard response == .OK else { return }
        onChoose(panel.urls)
    }

    func addFiles(_ urls: [URL]) {
        let staged = stager.stage(urls)
        let added = staged.urls.map { PrintComposerDocument(document: QueuedDocument(fileURL: $0)) }
        selectedDocument?.finishTextEditing()
        documents.append(contentsOf: added)
        if let first = added.first {
            selectedDocumentID = first.id
            scrollRequest = UUID()
        }
        observeDocuments()
        errorMessage = staged.failedCount > 0
            ? "Couldn’t add \(staged.failedCount) \(staged.failedCount == 1 ? "file" : "files")"
            : nil
    }

    func addDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !supported.isEmpty else { return false }
        pendingDocumentImports += 1
        let group = DispatchGroup()
        var urls = Array<URL?>(repeating: nil, count: supported.count)
        for (index, provider) in supported.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    urls[index] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            self.addFiles(urls.compactMap { $0 })
            self.pendingDocumentImports -= 1
        }
        return true
    }

    func cancel() {
        selectedDocument?.finishTextEditing()
        onFinish?(nil)
    }

    func done() {
        selectedDocument?.finishTextEditing()
        guard canFinish else { return }
        var output: [QueuedDocument] = []
        var generated: [URL] = []
        do {
            for document in documents {
                let pages = document.pages.compactMap(\.composition)
                var saved = document.original
                if document.loadFailed, var original = saved {
                    original.sides = document.sides
                    output.append(original)
                    continue
                }
                if saved == nil && pages.allSatisfy({ $0.items.isEmpty }) { continue }
                let changed = document.pages.contains { $0.hasChanges }
                if !pages.isEmpty && (changed || saved == nil) {
                    if document.pages.allSatisfy(\.isDefault), var original = saved,
                       !original.startedFromBlankCanvas {
                        original.fileURL = original.originalFileURL
                        original.layoutPages = nil
                        saved = original
                    } else {
                        let name = (document.title as NSString).deletingPathExtension
                        let url = try stager.makeComposedDocumentURL(named: "\(name) layout.pdf")
                        generated.append(url)
                        let sources = document.pages.reduce(into: [URL: PrintSource]()) { result, page in
                            result.merge(page.sources) { _, new in new }
                        }
                        try PrintCompositionRenderer.render(pages, sources: sources, to: url)
                        if var original = saved {
                            original.fileURL = url
                            original.layoutPages = pages
                            saved = original
                        } else {
                            saved = QueuedDocument(id: document.id, fileURL: url, layoutPages: pages, startedFromBlankCanvas: true)
                        }
                    }
                }
                if var saved {
                    saved.sides = document.sides
                    output.append(saved)
                }
            }
            let selectedID = output.first { $0.id == selectedDocumentID }?.id ?? output.first?.id
            onFinish?(PrintComposerResult(
                documents: output,
                selectedDocumentID: selectedID,
                originalDocumentIDs: originalDocumentIDs
            ))
        } catch {
            for url in generated { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            errorMessage = "Couldn’t save the documents"
        }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              NSApp.modalWindow == nil, !(window.firstResponder is NSTextView),
              let press = PrettyPrintKeyPress(event),
              let action = PrettyPrintShortcuts.shared.action(for: press, in: .editor) else { return false }
        switch action {
        case .done: done()
        case .cancel: cancel()
        case .addFiles: chooseFiles()
        case .previousPage, .nextPage:
            movePage(offset: action == .previousPage ? -1 : 1)
        default: return activePage?.handleKeyDown(event) ?? false
        }
        return true
    }

    private func observeDocuments() {
        subscriptions = documents.map { document in
            document.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
}
