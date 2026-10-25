import SwiftUI

struct RecentLayoutItemsView: View {
    let onSelect: (RecentLayoutItem) -> Void
    @ObservedObject private var store = RecentLayoutItemsStore.shared
    @ObservedObject private var fileNames = FileRenameCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent items")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if store.items.isEmpty {
                        Text("No recent items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                    ForEach(store.items) { item in row(item) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }

    private func row(_ item: RecentLayoutItem) -> some View {
        let title: String
        let detail: String
        let available: Bool
        switch item.content {
        case .file(let file):
            let url = file.resolvedURL
            title = url.lastPathComponent
            detail = url.path
            available = FileManager.default.isReadableFile(atPath: url.path)
        case .text(let text):
            title = text.title
            detail = "\(text.font.title) · \(Double(text.fontSize).formatted(.number.precision(.fractionLength(0...1)))) pt"
            available = true
        }

        return HStack(spacing: 2) {
            Button { onSelect(item) } label: {
                HStack(spacing: 8) {
                    thumbnail(item.content)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(available ? detail : "File unavailable\n\(detail)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .prettyPrintHoverHighlight(.row)
            .prettyPrintButtonCursor()
            .disabled(!available)
            .help(detail)
            .accessibilityLabel("Add \(title) to page")

            Button { store.remove(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .frame(width: 22, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .prettyPrintHoverHighlight(.destructive)
            .prettyPrintButtonCursor()
            .help("Remove from recent items")
            .accessibilityLabel("Remove \(title) from recent items")
        }
    }

    @ViewBuilder
    private func thumbnail(_ content: RecentLayoutContent) -> some View {
        switch content {
        case .file(let file):
            FileThumbnailView(url: file.resolvedURL, size: 42)
                .background(.white, in: RoundedRectangle(cornerRadius: 4))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .text(let text):
            Text(text.string)
                .font(.custom(text.font.rawValue, size: 11))
                .foregroundStyle(.black)
                .lineLimit(3)
                .frame(width: 36, height: 36)
                .padding(3)
                .background(.white, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        }
    }
}
