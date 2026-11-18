import AppKit
import SwiftUI

struct PrettyPrintDocumentThumbnailItem: View {
    let document: QueuedDocument
    let isPrinting: Bool
    let isSelected: Bool
    let onSelect: (QueuedDocument.ID) -> Void
    let onPreview: (QueuedDocument.ID) -> Void
    let onRemove: (QueuedDocument.ID) -> Void
    let onCopiesChange: (QueuedDocument.ID, Int) -> Void

    @ObservedObject private var renameCoordinator = FileRenameCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var showsPreviewOverlay: Bool { isHovering && !isPrinting }

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

    private var thumbnail: some View {
        Button {
            onSelect(document.id)
            onPreview(document.id)
        } label: {
            FileThumbnailView(url: document.fileURL)
                .saturation(showsPreviewOverlay ? 0 : 1)
                .opacity(showsPreviewOverlay ? 0.48 : 1)
                .background(PrettyPrintTileFill())
                .overlay {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
                        .opacity(showsPreviewOverlay ? 1 : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(isSelected ? 0.6 : 0), lineWidth: 1.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Preview \(fileName)")
        .help("Preview and arrange")
        .prettyPrintButtonCursor()
        .disabled(isPrinting)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsPreviewOverlay)
    }

    var body: some View {
        VStack(spacing: 5) {
            thumbnail

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
                onChange: { onCopiesChange(document.id, $0) },
                onRemove: { onRemove(document.id) }
            )
        }
        .frame(width: 90)
    }
}
