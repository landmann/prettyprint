import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PrintComposerSessionView: View {
    @ObservedObject var session: PrintComposerSession
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if !session.documents.isEmpty {
                    ComposerDocumentPages(session: session)
                } else {
                    ContentUnavailableView {
                        Label("No documents", systemImage: "doc")
                    } actions: {
                        Button("Add files", action: session.chooseFiles)
                            .prettyPrintButtonCursor()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !session.documents.isEmpty {
                    Divider()
                    ComposerDocumentCarousel(session: session)
                }
            }
            Divider()
            sidebar
                .frame(width: 280)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await session.loadCapabilities() }
        .task(id: session.selectedDocumentID) { await session.loadSelectedDocument() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: session.addDroppedFiles)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document = session.selectedDocument {
                ComposerDocumentHeading(document: document, paper: session.paper)
                VStack(spacing: 10) {
                    Menu {
                        Button("Add documents…", action: session.chooseFiles)
                        Button("Add to this page…", action: session.choosePageFiles)
                            .disabled(session.activePage == nil)
                    } label: {
                        ComposerActionLabel("Add file", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .composerLargeButton(.accent)
                    if let page = session.activePage {
                        ComposerPageTools(model: page)
                    }
                    ComposerPrintSides(document: document, supportedSides: session.supportedSides)
                }
                .padding(12)
                Divider()
                if let page = session.activePage {
                    PrintComposerInspector(model: page)
                        .id(ObjectIdentifier(page))
                } else {
                    Spacer()
                }
            } else {
                Spacer()
            }
            Divider()
            actions
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = session.errorMessage ?? session.activePage?.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button { session.activePage?.reset() } label: {
                    ComposerActionLabel("Reset")
                }
                .buttonStyle(.bordered)
                .composerLargeButton(.accent)
                .disabled(!(session.activePage?.canReset ?? false))
                .help("Reset the selected page")
                Button(action: session.cancel) {
                    ComposerActionLabel("Cancel")
                }
                .buttonStyle(.bordered)
                .composerLargeButton(.accent)
                Button(action: session.done) {
                    ComposerActionLabel("Done")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .composerLargeButton(.primary)
                .disabled(!session.canFinish)
            }
        }
        .padding(12)
    }


}

private struct ComposerDocumentHeading: View {
    @ObservedObject var document: PrintComposerDocument
    let paper: PrintPaper
    @ObservedObject private var fileNames = FileRenameCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(document.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(document.title)
            Text(paper.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding([.top, .horizontal], 12)
    }
}

private struct ComposerPageTools: View {
    @ObservedObject var model: PrintComposerModel

    var body: some View {
        Button(action: model.addText) {
            ComposerActionLabel("Add text", systemImage: "textformat")
        }
        .buttonStyle(.bordered)
        .composerLargeButton(.accent)
        .disabled(model.composition == nil)
        PrintComposerGridControls(model: model)
    }
}

private struct ComposerPrintSides: View {
    @ObservedObject var document: PrintComposerDocument
    let supportedSides: [PrintSides]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Printing", selection: $document.sides) {
                ForEach(PrintSides.allCases) { sides in
                    Text(sides.title).tag(sides)
                        .disabled(!(supportedSides?.contains(sides) ?? false))
                }
            }
            .disabled(supportedSides == nil)
            .prettyPrintButtonCursor()
            if supportedSides == nil {
                Text("Checking double-sided support…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if supportedSides?.count == 1 {
                Text("Double-sided printing isn’t available for this printer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct ComposerDocumentPages: View {
    @ObservedObject var session: PrintComposerSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visiblePage: ComposerPageID?

    init(session: PrintComposerSession) {
        self.session = session
        _visiblePage = State(initialValue: session.selectedDocument.map {
            ComposerPageID(documentID: $0.id, pageIndex: $0.selectedPageIndex)
        })
    }

    private var pages: [ComposerPage] {
        session.documents.flatMap { document in
            let count = document.loadFailed ? 1 : max(1, document.pages.count)
            return (0..<count).map { ComposerPage(document: document, index: $0) }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let fittedPage = session.paper.fittedSize(in: CGSize(
                width: max(1, geometry.size.width - PrintPageRulers.canvasInsets.width),
                height: max(1, geometry.size.height - PrintPageRulers.canvasInsets.height)
            ))
            let canvasWidth = fittedPage.width + PrintPageRulers.canvasInsets.width
            let sidePadding = max(0, (geometry.size.width - canvasWidth) / 2)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages) { page in
                        pageView(page)
                            .frame(width: canvasWidth, height: geometry.size.height)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("\(page.document.title), page \(page.index + 1) of \(max(1, page.document.pages.count))")
                            .id(page.id)
                            .task {
                                await session.loadDocument(page.document)
                            }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, sidePadding)
                .frame(height: geometry.size.height)
            }
            .scrollPosition(id: $visiblePage, anchor: .center)
            .onChange(of: visiblePage) { _, pageID in
                if let pageID,
                   let document = session.documents.first(where: { $0.id == pageID.documentID }) {
                    session.selectPage(pageID.pageIndex, in: document)
                }
            }
            .onChange(of: session.scrollRequest) { _, _ in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    visiblePage = session.selectedDocument.map {
                        ComposerPageID(documentID: $0.id, pageIndex: $0.selectedPageIndex)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                ComposerPageNavigation(session: session)
                    .padding(.bottom, max(8, (geometry.size.height - fittedPage.height) / 4 - 14))
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private func pageView(_ page: ComposerPage) -> some View {
        if page.document.loadFailed {
            ContentUnavailableView {
                Label("Preview unavailable", systemImage: "doc.badge.ellipsis")
            } description: {
                Text("This document will stay unchanged.")
            }
        } else if page.document.pages.indices.contains(page.index) {
            PrintComposerCanvas(
                model: page.document.pages[page.index],
                isActive: page.document.id == session.selectedDocumentID
                    && page.index == page.document.selectedPageIndex,
                onActivate: { session.selectPage(page.index, in: page.document) }
            )
        } else {
            ProgressView()
        }
    }
}

private struct ComposerPageNavigation: View {
    @ObservedObject var session: PrintComposerSession

    private var pageLabel: String {
        guard let document = session.selectedDocument,
              !document.pages.isEmpty || document.loadFailed else { return "–/–" }
        return "\(document.selectedPageIndex + 1)/\(document.loadFailed ? 1 : document.pages.count)"
    }

    var body: some View {
        HStack(spacing: 0) {
            pageButton(offset: -1, isEnabled: session.canGoToPreviousPage)
            Divider().frame(height: 16)
            Text(pageLabel)
                .font(.caption)
                .monospacedDigit()
                .frame(minWidth: 48)
                .accessibilityLabel("Page \(pageLabel)")
            Divider().frame(height: 16)
            pageButton(offset: 1, isEnabled: session.canGoToNextPage)
        }
        .fixedSize()
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func pageButton(offset: Int, isEnabled: Bool) -> some View {
        Button { session.movePage(offset: offset) } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.primary : .secondary.opacity(0.5))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .prettyPrintHoverHighlight(.selection)
        .prettyPrintButtonCursor()
        .disabled(!isEnabled)
        .accessibilityLabel(offset < 0 ? "Previous page" : "Next page")
        .help(offset < 0 ? "Previous page (←)" : "Next page (→)")
    }
}

private struct ComposerPageID: Hashable {
    let documentID: UUID
    let pageIndex: Int
}

private struct ComposerPage: Identifiable {
    let document: PrintComposerDocument
    let index: Int

    var id: ComposerPageID {
        ComposerPageID(documentID: document.id, pageIndex: index)
    }
}

private struct ComposerDocumentCarousel: View {
    @ObservedObject var session: PrintComposerSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(session.documents) { document in
                        ComposerDocumentCard(
                            document: document,
                            isSelected: document.id == session.selectedDocumentID,
                            onSelect: { session.selectDocument(document.id) },
                            onRemove: { session.removeDocument(document.id) }
                        )
                        .id(document.id)
                    }
                }
                .padding(12)
            }
            .frame(height: 136)
            .onChange(of: session.selectedDocumentID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let id = session.selectedDocumentID { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ComposerDocumentCard: View {
    @ObservedObject var document: PrintComposerDocument
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    @ObservedObject private var fileNames = FileRenameCoordinator.shared

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 7) {
                if let url = document.original?.fileURL {
                    FileThumbnailView(url: url, size: 62)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 36))
                        .frame(width: 62, height: 62)
                }
                Text(document.title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 124)
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .prettyPrintHoverHighlight(.selection)
        .prettyPrintButtonCursor()
        .help(document.title)
        .accessibilityLabel("Edit \(document.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .prettyPrintHoverHighlight(.destructive)
            .prettyPrintButtonCursor()
            .help("Remove document")
            .accessibilityLabel("Remove \(document.title)")
            .padding(5)
        }
    }
}
