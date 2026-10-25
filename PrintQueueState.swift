import Foundation

struct QueuedDocument: Identifiable, Equatable {
    static let minimumCopies = 1
    static let maximumCopies = 20

    let id: UUID
    var fileURL: URL
    var copies: Int
    var layoutPages: [PrintComposition]?
    var sides: PrintSides
    var startedFromBlankCanvas: Bool
    let originalFileURL: URL

    init(
        id: UUID = UUID(),
        fileURL: URL,
        copies: Int = minimumCopies,
        layoutPages: [PrintComposition]? = nil,
        sides: PrintSides = .oneSided,
        startedFromBlankCanvas: Bool = false
    ) {
        self.id = id
        self.fileURL = fileURL
        self.originalFileURL = fileURL
        self.copies = Self.clampedCopies(copies)
        self.layoutPages = layoutPages
        self.sides = sides
        self.startedFromBlankCanvas = startedFromBlankCanvas
    }

    static func clampedCopies(_ copies: Int) -> Int {
        min(max(copies, minimumCopies), maximumCopies)
    }
}

struct PrintQueueCompletion: Equatable {
    let remainingQueue: [QueuedDocument]
    let successfulDocuments: [QueuedDocument]
}

func reducePrintQueueCompletion(
    submitted: [QueuedDocument],
    currentQueue: [QueuedDocument],
    submittedCopies: [Int]
) -> PrintQueueCompletion {
    guard submittedCopies.count == submitted.count,
          zip(submittedCopies, submitted).allSatisfy({ count, document in
              count >= 0 && count <= document.copies
          }) else {
        return PrintQueueCompletion(
            remainingQueue: currentQueue,
            successfulDocuments: []
        )
    }

    let successfulDocuments = submitted.enumerated().compactMap { index, document -> QueuedDocument? in
        guard submittedCopies[index] > 0 else { return nil }
        var sent = document
        sent.copies = submittedCopies[index]
        return sent
    }
    let countsByID = Dictionary(uniqueKeysWithValues: successfulDocuments.map { ($0.id, $0.copies) })
    let remainingQueue = currentQueue.compactMap { document -> QueuedDocument? in
        guard let sent = countsByID[document.id] else { return document }
        guard document.copies > sent else { return nil }
        var remaining = document
        remaining.copies -= sent
        return remaining
    }

    return PrintQueueCompletion(
        remainingQueue: remainingQueue,
        successfulDocuments: successfulDocuments
    )
}
