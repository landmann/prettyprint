import Foundation

struct Printer: Identifiable, Equatable {
    let id: String
    let name: String
    let status: PrinterStatus
    var singleCopyHelper: URL? = nil
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
        let printers = await withTaskGroup(of: (Int, Printer?).self) { group in
            for (index, queue) in queues.enumerated() {
                group.addTask { (index, await installedPrinter(queue)) }
            }
            var loaded: [(Int, Printer)] = []
            for await (index, printer) in group {
                if let printer { loaded.append((index, printer)) }
            }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return (printers, defaultPrinterID(inLpstatOutput: await defaultOutput ?? ""))
    }

    static func capabilities(for printer: Printer) async -> PrinterCapabilities {
        let output = await ProcessRunner.output(lpoptions, ["-p", printer.id, "-l"]) ?? ""
        let capabilities = capabilities(inOptions: output)
        guard printer.singleCopyHelper != nil else { return capabilities }
        return PrinterCapabilities(paper: capabilities.paper, sides: [.oneSided])
    }

    private static func installedPrinter(_ queue: String) async -> Printer? {
        let options = parseOptions(await ProcessRunner.output(lpoptions, ["-p", queue]) ?? "")
        guard isInstalledQueue(options) else { return nil }
        let info = options["printer-info"].flatMap { $0.isEmpty || $0 == queue ? nil : $0 }
        let helper = options["device-uri"].flatMap(singleCopyHelper(for:))
        var status = helper == nil ? status(queue: queue, options: options) : .ready
        if let helper, !isExecutableFile(helper) {
            status = .unavailable
        } else if status.canPrint {
            switch await options["device-uri"].asyncMap(PrinterReachability.reach(deviceURI:)) {
            case .reachable?: break
            case .unreachable?: status = .offline
            case .localNetworkBlocked?: status = .localNetworkBlocked
            case .unconfirmed?, nil: status = .unavailable
            }
        }
        return Printer(
            id: queue, name: info ?? queue.replacingOccurrences(of: "_", with: " "), status: status,
            singleCopyHelper: helper
        )
    }

    static func isInstalledQueue(_ options: [String: String]) -> Bool {
        options["printer-uri-supported"] != nil
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        return (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isExecutableFile(atPath: target.path)
    }

    private static func singleCopyHelper(for deviceURI: String) -> URL? {
        guard case .bluetooth(let address) = PrinterReachability.target(forDeviceURI: deviceURI) else { return nil }
        let directory = URL.applicationSupportDirectory
            .appending(path: "PrettyPrint/Bluetooth Printers", directoryHint: .isDirectory)
            .appending(path: address.filter(\.isHexDigit).uppercased(), directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return directory.appending(path: "print-one-copy")
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
    private(set) var refreshTask: Task<Void, Never>?
    private var capabilities: [String: PrinterCapabilities] = [:]

    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            let loaded = await PrinterDirectory.load()
            for printer in loaded.printers where capabilities[printer.id] == nil {
                capabilities[printer.id] = await PrinterDirectory.capabilities(for: printer)
            }
            printers = loaded.printers
            defaultPrinterID = loaded.defaultID
            hasLoaded = true
            refreshTask = nil
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
