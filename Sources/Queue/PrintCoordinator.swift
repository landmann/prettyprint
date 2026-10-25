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
    typealias InvocationRunner = @MainActor (
        PrintInvocation,
        @escaping @MainActor (Bool) -> Void
    ) -> Void
    typealias SidesReader = (String) async -> [PrintSides]

    private struct Job {
        let invocation: PrintInvocation
        let documentIndex: Int
        let copies: Int
    }

    static func invocations(
        for fileURLs: [URL],
        printerID: String
    ) -> [PrintInvocation] {
        invocations(
            for: fileURLs.map { QueuedDocument(fileURL: $0) },
            printerID: printerID
        )
    }

    static func invocations(
        for documents: [QueuedDocument],
        printerID: String
    ) -> [PrintInvocation] {
        jobs(for: documents, printerID: printerID).map(\.invocation)
    }

    private static func jobs(for documents: [QueuedDocument], printerID: String) -> [Job] {
        documents.enumerated().map { index, document in
            Job(invocation: PrintInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/lp"),
                arguments: [
                    "-d", printerID,
                    "-n", String(document.copies),
                    "-o", "sides=\(document.sides.cupsValue)",
                    document.fileURL.path
                ]
            ), documentIndex: index, copies: document.copies)
        }
    }

    @MainActor
    static func submit(
        _ fileURLs: [URL],
        printerID: String,
        runner: @escaping InvocationRunner = run,
        sidesReader: @escaping SidesReader = { await PrinterDirectory.capabilities(for: $0).sides },
        completion: @escaping @MainActor (PrintBatchResult) -> Void
    ) {
        submit(
            fileURLs.map { QueuedDocument(fileURL: $0) },
            printerID: printerID,
            runner: runner,
            sidesReader: sidesReader,
            completion: completion
        )
    }

    @MainActor
    static func submit(
        _ documents: [QueuedDocument],
        printerID: String,
        runner: @escaping InvocationRunner = run,
        sidesReader: @escaping SidesReader = { await PrinterDirectory.capabilities(for: $0).sides },
        progress: @escaping @MainActor (PrintBatchProgress) -> Void = { _ in },
        completion: @escaping @MainActor (PrintBatchResult) -> Void
    ) {
        func start() {
            runNext(
                documents,
                jobs(for: documents, printerID: printerID),
                index: 0,
                submittedCopies: Array(repeating: 0, count: documents.count),
                runner: runner,
                progress: progress,
                completion: completion
            )
        }

        progress(PrintBatchProgress(submittedCopies: 0, totalCopies: documents.reduce(0) { $0 + $1.copies }))
        let requestedSides = Set(documents.map(\.sides))
        guard requestedSides.contains(where: { $0 != .oneSided }) else {
            start()
            return
        }
        Task { @MainActor in
            let supportedSides = await sidesReader(printerID)
            guard requestedSides.isSubset(of: supportedSides) else {
                completion(result(
                    for: documents,
                    submittedCopies: Array(repeating: 0, count: documents.count)
                ))
                return
            }
            start()
        }
    }

    private static func result(
        for documents: [QueuedDocument],
        submittedCopies: [Int]
    ) -> PrintBatchResult {
        PrintBatchResult(documentResults: zip(documents, submittedCopies).map { document, count in
            PrintDocumentResult(
                fileURL: document.fileURL,
                requestedCopies: document.copies,
                submittedCopies: count
            )
        })
    }

    @MainActor
    private static func runNext(
        _ documents: [QueuedDocument],
        _ jobs: [Job],
        index: Int,
        submittedCopies: [Int],
        runner: @escaping InvocationRunner,
        progress: @escaping @MainActor (PrintBatchProgress) -> Void,
        completion: @escaping @MainActor (PrintBatchResult) -> Void
    ) {
        func finish() {
            completion(result(for: documents, submittedCopies: submittedCopies))
        }

        guard index < jobs.count else {
            finish()
            return
        }

        let job = jobs[index]
        runner(job.invocation) { didSucceed in
            guard didSucceed else {
                finish()
                return
            }
            var counts = submittedCopies
            counts[job.documentIndex] += job.copies
            progress(PrintBatchProgress(
                submittedCopies: counts.reduce(0, +),
                totalCopies: documents.reduce(0) { $0 + $1.copies }
            ))
            runNext(
                documents,
                jobs,
                index: index + 1,
                submittedCopies: counts,
                runner: runner,
                progress: progress,
                completion: completion
            )
        }
    }

    @MainActor
    private static func run(
        _ invocation: PrintInvocation,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.terminationHandler = { process in
            let invocationSucceeded = process.terminationReason == .exit && process.terminationStatus == 0
            Task { @MainActor in
                completion(invocationSucceeded)
            }
        }

        do {
            try process.run()
        } catch {
            completion(false)
        }
    }
}
