import Foundation

struct PrintInvocation: Equatable {
    let executableURL: URL
    let arguments: [String]
}

struct PrintDocumentResult: Equatable {
    let fileURL: URL
    let requestedCopies: Int
    let submittedCopies: Int

    var didSucceed: Bool { submittedCopies == requestedCopies }
}

struct PrintBatchProgress: Equatable {
    let submittedCopies: Int
    let totalCopies: Int
}

struct PrintBatchResult: Equatable {
    let documentResults: [PrintDocumentResult]

    var succeeded: Int {
        documentResults.count(where: \.didSucceed)
    }

    var failed: Int {
        documentResults.count - succeeded
    }

    var submittedCopies: Int { documentResults.reduce(0) { $0 + $1.submittedCopies } }
    var requestedCopies: Int { documentResults.reduce(0) { $0 + $1.requestedCopies } }
}

enum PrintBatchCoordinator {
    @MainActor
    static func submit(
        _ documents: [QueuedDocument],
        to printer: Printer,
        runner: @MainActor (PrintInvocation) async -> Bool = { invocation in
            await ProcessRunner.succeeds(invocation.executableURL, invocation.arguments)
        },
        progress: @MainActor (PrintBatchProgress) -> Void = { _ in }
    ) async -> PrintBatchResult {
        var counts = Array(repeating: 0, count: documents.count)
        let total = documents.reduce(0) { $0 + $1.copies }
        var sent = 0

        func result() -> PrintBatchResult {
            PrintBatchResult(documentResults: zip(documents, counts).map { document, count in
                PrintDocumentResult(fileURL: document.fileURL, requestedCopies: document.copies, submittedCopies: count)
            })
        }

        progress(PrintBatchProgress(submittedCopies: 0, totalCopies: total))
        let requestedSides = Set(documents.map(\.sides))
        if requestedSides.contains(where: { $0 != .oneSided }) {
            guard printer.singleCopyHelper == nil else { return result() }
            let supported = await PrinterDirectory.capabilities(for: printer).sides
            guard requestedSides.isSubset(of: supported) else { return result() }
        }

        for (index, document) in documents.enumerated() {
            let invocation: PrintInvocation
            let copiesPerSubmission: Int
            if let helper = printer.singleCopyHelper {
                invocation = PrintInvocation(executableURL: helper, arguments: [document.fileURL.path])
                copiesPerSubmission = 1
            } else {
                invocation = PrintInvocation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/lp"),
                    arguments: ["-d", printer.id, "-n", String(document.copies),
                                "-o", "sides=\(document.sides.cupsValue)", document.fileURL.path]
                )
                copiesPerSubmission = document.copies
            }

            while counts[index] < document.copies {
                guard await runner(invocation) else { return result() }
                counts[index] += copiesPerSubmission
                sent += copiesPerSubmission
                progress(PrintBatchProgress(submittedCopies: sent, totalCopies: total))
            }
        }
        return result()
    }
}
