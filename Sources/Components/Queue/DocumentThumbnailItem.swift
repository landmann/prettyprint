import AppKit
import QuickLookThumbnailing
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

struct PrettyPrintThumbnailActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        PrettyPrintThumbnailActionButton(configuration: configuration, tint: tint)
    }
}

struct PrettyPrintThumbnailActionButton: View {
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
