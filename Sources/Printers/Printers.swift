import Foundation

struct Printer: Identifiable, Equatable {
    let id: String
    let name: String
    let status: PrinterStatus
}

struct PrinterCapabilities: Equatable {
    let paper: PrintPaper
    let sides: [PrintSides]
}

enum PrinterDirectory {
    static let lpstat = "/usr/bin/lpstat"
    static let lpoptions = "/usr/bin/lpoptions"

    static func load() async -> (printers: [Printer], defaultID: String?) {
        async let queueOutput = ProcessRunner.output(lpstat, ["-e"])
        async let defaultOutput = ProcessRunner.output(lpstat, ["-d"])
        let queues = (await queueOutput ?? "").split(whereSeparator: \.isNewline).map(String.init)
        let printers = await withTaskGroup(of: (Int, Printer).self) { group in
            for (index, queue) in queues.enumerated() {
                group.addTask { (index, await printer(queue)) }
            }
            var loaded: [(Int, Printer)] = []
            for await entry in group { loaded.append(entry) }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return (printers, defaultPrinterID(inLpstatOutput: await defaultOutput ?? ""))
    }

    static func capabilities(for queue: String) async -> PrinterCapabilities {
        let output = await ProcessRunner.output(lpoptions, ["-p", queue, "-l"]) ?? ""
        return capabilities(inOptions: output)
    }

    private static func printer(_ queue: String) async -> Printer {
        let options = parseOptions(await ProcessRunner.output(lpoptions, ["-p", queue]) ?? "")
        let info = options["printer-info"].flatMap { $0.isEmpty || $0 == queue ? nil : $0 }
        var status = status(queue: queue, options: options)
        if status.canPrint {
            let checked: Bool?? = await options["device-uri"].asyncMap(PrinterReachability.isReachable(deviceURI:))
            if let reachable = checked ?? nil {
                if !reachable { status = .offline }
            } else {
                status = .unavailable
            }
        }
        return Printer(id: queue, name: info ?? queue.replacingOccurrences(of: "_", with: " "), status: status)
    }

    static func defaultPrinterID(inLpstatOutput output: String) -> String? {
        guard let separator = output.range(of: ": ") else { return nil }
        let name = output[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func parseOptions(_ text: String) -> [String: String] {
        var options: [String: String] = [:]
        var key = ""
        var value = ""
        var readingValue = false
        var quote: Character?
        var escaping = false

        func finish() {
            if !key.isEmpty { options[key] = value }
            key = ""
            value = ""
            readingValue = false
        }

        for character in text {
            if escaping {
                if readingValue { value.append(character) } else { key.append(character) }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if let open = quote {
                if character == open { quote = nil } else { value.append(character) }
            } else if readingValue, character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                finish()
            } else if !readingValue, character == "=" {
                readingValue = true
            } else if readingValue {
                value.append(character)
            } else {
                key.append(character)
            }
        }
        finish()
        return options
    }

    static func status(queue: String, options: [String: String]) -> PrinterStatus {
        guard let uri = options["printer-uri-supported"],
              URL(string: uri)?.lastPathComponent == queue,
              let state = options["printer-state"],
              let acceptingJobs = options["printer-is-accepting-jobs"],
              let reportedReasons = options["printer-state-reasons"] else { return .unavailable }
        let reasons = reportedReasons.split(separator: ",").map(String.init)
        if reasons.contains(where: { $0.hasPrefix("media-empty") || $0.hasPrefix("media-needed") }) {
            return .paperNeeded
        }
        if reasons.contains(where: {
            $0.hasPrefix("offline") || $0.hasPrefix("connecting-to-device")
                || $0.hasPrefix("timed-out") || $0.hasPrefix("printer-unreachable")
        }) {
            return .offline
        }
        if state == "5" || reasons.contains("paused") { return .paused }
        guard acceptingJobs == "true" else { return .unavailable }
        if reasons.contains(where: {
            $0.hasSuffix("-error") || $0.hasPrefix("media-jam") || $0.hasPrefix("door-open")
                || $0.hasPrefix("cover-open") || $0.hasPrefix("marker-supply-empty")
                || $0.hasPrefix("toner-empty")
        }) {
            return .attention
        }
        switch state {
        case "3": return .ready
        case "4": return .printing
        default: return .unavailable
        }
    }

    static func capabilities(inOptions options: String) -> PrinterCapabilities {
        let lines = options.split(whereSeparator: \.isNewline)
        let paper = lines.lazy.compactMap(defaultPageSize(in:)).compactMap(PrintPaper.init(pageSizeName:)).first
        let choices = Set(lines.flatMap(duplexChoices(in:)))
        let sides = PrintSides.allCases.filter {
            $0 == .oneSided || !advertisedChoices(for: $0).isDisjoint(with: choices)
        }
        return PrinterCapabilities(paper: paper ?? .localDefault, sides: sides)
    }

    private static func defaultPageSize(in line: Substring) -> String? {
        guard let separator = line.firstIndex(of: ":"),
              line.prefix(while: { $0 != "/" && $0 != ":" }).lowercased() == "pagesize" else { return nil }
        return line[line.index(after: separator)...]
            .split(whereSeparator: \.isWhitespace)
            .first { $0.hasPrefix("*") }
            .map { String($0.dropFirst()) }
    }

    private static func advertisedChoices(for sides: PrintSides) -> Set<String> {
        switch sides {
        case .oneSided: []
        case .longEdge: ["DuplexNoTumble", "two-sided-long-edge"]
        case .shortEdge: ["DuplexTumble", "two-sided-short-edge"]
        }
    }

    private static func duplexChoices(in line: Substring) -> [String] {
        guard let separator = line.lastIndex(of: ":") else { return [] }
        let keyword = line.prefix { $0 != "/" && $0 != ":" }.lowercased()
        guard keyword == "sides" || keyword.contains("duplex") else { return [] }
        return line[line.index(after: separator)...]
            .split(whereSeparator: \.isWhitespace)
            .map { choice in String(choice.drop { $0 == "*" }) }
    }
}

@MainActor
final class PrinterStore: ObservableObject {
    @Published private(set) var printers: [Printer] = []
    @Published private(set) var defaultPrinterID: String?
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRefreshing = false
    private var capabilities: [String: PrinterCapabilities] = [:]

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let loaded = await PrinterDirectory.load()
            for printer in loaded.printers where capabilities[printer.id] == nil {
                capabilities[printer.id] = await PrinterDirectory.capabilities(for: printer.id)
            }
            printers = loaded.printers
            defaultPrinterID = loaded.defaultID
            hasLoaded = true
            isRefreshing = false
        }
    }

    func paper(for printerID: String) -> PrintPaper {
        capabilities[printerID]?.paper ?? .localDefault
    }

    func printer(_ id: String) -> Printer? {
        printers.first { $0.id == id }
    }
}

extension Optional {
    func asyncMap<Mapped>(_ transform: (Wrapped) async -> Mapped) async -> Mapped? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
