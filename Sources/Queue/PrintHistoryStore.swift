import Combine
import Foundation

struct PrintedDocumentRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let fileURL: URL
    let printedAt: Date

    init(id: UUID = UUID(), fileURL: URL, printedAt: Date) {
        self.id = id
        self.fileURL = fileURL
        self.printedAt = printedAt
    }
}

final class PrintHistoryStore: ObservableObject {
    static let storageKey = "printHistory.v1"
    static let maximumRecordCount = 5

    @Published private(set) var records: [PrintedDocumentRecord]

    private let defaults: UserDefaults
    private let dateProvider: () -> Date

    init(
        defaults: UserDefaults = .standard,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.dateProvider = dateProvider
        self.records = Self.loadRecords(from: defaults)
        saveRecords()
    }

    func recordSuccessfulPrints(_ fileURLs: [URL], printedAt: Date? = nil) {
        guard !fileURLs.isEmpty else { return }

        let date = printedAt ?? dateProvider()
        let batch = fileURLs.reversed().map {
            PrintedDocumentRecord(fileURL: $0, printedAt: date)
        }

        records = Self.recentUniqueRecords(batch + records)
        saveRecords()
    }

    private func saveRecords() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func loadRecords(from defaults: UserDefaults) -> [PrintedDocumentRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([PrintedDocumentRecord].self, from: data)
        else {
            return []
        }

        return recentUniqueRecords(records)
    }

    private static func recentUniqueRecords(_ records: [PrintedDocumentRecord]) -> [PrintedDocumentRecord] {
        let stager = PrettyPrintDocumentStager()
        var seen = Set<URL>()
        let newestFirst = records.enumerated().sorted { left, right in
            if left.element.printedAt != right.element.printedAt {
                return left.element.printedAt > right.element.printedAt
            }
            return left.offset < right.offset
        }
        let unique = newestFirst.compactMap { entry -> PrintedDocumentRecord? in
            let record = entry.element
            let originalURL = stager.originalURL(for: record.fileURL) ?? record.fileURL
            let identity = originalURL.standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(identity).inserted ? record : nil
        }
        return Array(unique.prefix(maximumRecordCount))
    }
}
