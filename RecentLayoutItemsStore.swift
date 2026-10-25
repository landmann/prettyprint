import Combine
import Foundation

struct RecentLayoutFile: Codable, Equatable {
    let url: URL
    let bookmark: Data?

    init(url: URL) {
        self.url = url
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    var resolvedURL: URL {
        guard let bookmark else { return url }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                         relativeTo: nil, bookmarkDataIsStale: &stale)) ?? url
    }
}

enum RecentLayoutContent: Codable, Equatable {
    case file(RecentLayoutFile)
    case text(PrintText)

    fileprivate enum Identity: Hashable {
        case file(URL)
        case text(String)
    }

    fileprivate var identity: Identity {
        switch self {
        case .file(let file): .file(file.resolvedURL.standardizedFileURL.resolvingSymlinksInPath())
        case .text(let text): .text(text.string)
        }
    }
}

struct RecentLayoutItem: Identifiable, Codable, Equatable {
    let id: UUID
    let content: RecentLayoutContent
}

@MainActor
final class RecentLayoutItemsStore: ObservableObject {
    static let shared = RecentLayoutItemsStore()
    private static let storageKey = "recentLayoutItems.v1"
    private static let limit = 10

    @Published private(set) var items: [RecentLayoutItem]
    private let defaults: UserDefaults
    private let stager = PrettyPrintDocumentStager()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([RecentLayoutItem].self, from: data) {
            items = Self.unique(saved)
        } else {
            items = Self.unique(stager.previouslyImportedSources().map {
                RecentLayoutItem(id: UUID(), content: .file(RecentLayoutFile(url: $0)))
            })
        }
        save()
    }

    func rememberFile(_ url: URL) {
        guard let source = stager.sourceURL(for: url) else { return }
        remember(.file(RecentLayoutFile(url: source)))
    }

    func rememberText(_ text: PrintText) {
        guard text.isValid, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        remember(.text(text))
    }

    func remove(_ id: RecentLayoutItem.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func remember(_ content: RecentLayoutContent) {
        let id = items.first { $0.content.identity == content.identity }?.id ?? UUID()
        items = Self.unique([RecentLayoutItem(id: id, content: content)] + items)
        save()
    }

    private static func unique(_ items: [RecentLayoutItem]) -> [RecentLayoutItem] {
        var seen = Set<RecentLayoutContent.Identity>()
        return Array(items.filter { seen.insert($0.content.identity).inserted }.prefix(limit))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
