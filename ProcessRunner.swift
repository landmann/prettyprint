import Foundation

struct ProcessOutput {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { exitCode == 0 }
}

enum ProcessRunner {
    static let maximumOutputBytes = 1_048_576
    private static let drainGrace: TimeInterval = 2

    static func output(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) async -> String? {
        guard let result = await run(executable, arguments, timeout: timeout), result.succeeded else { return nil }
        return result.standardOutput
    }

    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 5,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        input: Data? = nil
    ) async -> ProcessOutput? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments, timeout, environment, currentDirectory, input))
            }
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var overflowed = false
        let finished = DispatchSemaphore(value: 0)

        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if data.count + chunk.count > ProcessRunner.maximumOutputBytes { overflowed = true }
            if !overflowed { data.append(chunk) }
            return !overflowed
        }

        var result: (Data, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, overflowed)
        }
    }

    private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval,
        _ environment: [String: String]?,
        _ currentDirectory: URL?,
        _ input: Data?
    ) -> ProcessOutput? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = Collector()
        let errors = Collector()
        let exited = DispatchSemaphore(value: 0)
        for (pipe, collector) in [(outputPipe, output), (errorPipe, errors)] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    collector.finished.signal()
                } else if !collector.append(chunk), process.isRunning {
                    process.terminate()
                }
            }
        }
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        if let input {
            DispatchQueue.global(qos: .utility).async {
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }

        let drainDeadline = DispatchTime.now() + drainGrace
        _ = output.finished.wait(timeout: drainDeadline)
        _ = errors.finished.wait(timeout: drainDeadline)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        let (outputData, overflowed) = output.result
        guard !timedOut, !overflowed, process.terminationReason == .exit else { return nil }
        return ProcessOutput(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errors.result.0, as: UTF8.self)
        )
    }
}
