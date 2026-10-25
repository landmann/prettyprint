import Foundation

struct DocumentStagingResult {
    let urls: [URL]
    let failedCount: Int
}

final class PrettyPrintDocumentStager {
    private let fileManager: FileManager
    private let storageDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        storageDirectory = applicationSupport
            .appendingPathComponent("PrettyPrint", isDirectory: true)
            .appendingPathComponent("Imported Documents", isDirectory: true)

        try? fileManager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }

    @MainActor
    func stage(_ urls: [URL]) -> DocumentStagingResult {
        var stagedURLs: [URL] = []
        var failedCount = 0

        for url in urls {
            guard url.isFileURL else {
                failedCount += 1
                continue
            }

            if url.standardizedFileURL.path.hasPrefix(storageDirectory.standardizedFileURL.path + "/") {
                stagedURLs.append(url)
                RecentLayoutItemsStore.shared.rememberFile(url)
                continue
            }

            let destinationDirectory = storageDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let destinationURL = destinationDirectory
                .appendingPathComponent(url.lastPathComponent)

            do {
                try fileManager.createDirectory(
                    at: destinationDirectory,
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: url, to: destinationURL)
                try? rememberOriginal(url, for: destinationURL)
                stagedURLs.append(destinationURL)
                RecentLayoutItemsStore.shared.rememberFile(url)
            } catch {
                try? fileManager.removeItem(at: destinationDirectory)
                failedCount += 1
            }
        }

        return DocumentStagingResult(urls: stagedURLs, failedCount: failedCount)
    }

    func makeComposedDocumentURL(named fileName: String) throws -> URL {
        let directory = storageDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    func sourceURL(for url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let managed = url.standardizedFileURL.path.hasPrefix(storageDirectory.standardizedFileURL.path + "/")
        return managed ? originalURL(for: url) : url
    }

    func previouslyImportedSources() -> [URL] {
        let bookmarks = (try? fileManager.contentsOfDirectory(
            at: storageDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return bookmarks.filter { $0.pathExtension == "bookmark" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                var stale = false
                return try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                relativeTo: nil, bookmarkDataIsStale: &stale)
            }
    }

    func originalURL(for stagedURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: originalBookmarkURL(for: stagedURL)) else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    func rememberOriginal(_ originalURL: URL, for stagedURL: URL) throws {
        let bookmark = try originalURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try bookmark.write(to: originalBookmarkURL(for: stagedURL), options: .atomic)
    }

    private func originalBookmarkURL(for stagedURL: URL) -> URL {
        let importID = stagedURL.deletingLastPathComponent().lastPathComponent
        return storageDirectory.appendingPathComponent("\(importID).bookmark")
    }
}
