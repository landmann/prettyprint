import Foundation

struct DiscoveredPrinter: Identifiable, Equatable {
    let uri: String
    let isNetwork: Bool
    let info: String
    let makeAndModel: String
    let deviceID: String

    var id: String { uri }

    var name: String {
        [info, makeAndModel].first { !$0.isEmpty && $0 != "Unknown" } ?? uri
    }

    var model: String {
        makeAndModel == "Unknown" || makeAndModel.isEmpty ? name : makeAndModel
    }

    var isDriverless: Bool {
        let scheme = uri.prefix { $0 != ":" }
        if scheme == "dnssd" { return uri.contains("._ipp._tcp") || uri.contains("._ipps._tcp") }
        return scheme == "ipp" || scheme == "ipps"
    }
}

enum PrinterSetupError: Error, Equatable {
    case notAuthorized
    case needsDriver
    case failed(String)

    var message: String {
        switch self {
        case .notAuthorized: "Ask an administrator to add this printer"
        case .needsDriver: "Needs a driver"
        case .failed(let detail): detail.isEmpty ? "Couldn’t add this printer" : detail
        }
    }
}

enum PrinterSetup {
    static let lpinfo = "/usr/sbin/lpinfo"
    static let lpadmin = "/usr/sbin/lpadmin"

    static func discover(excludingNames configuredNames: [String]) async -> [DiscoveredPrinter] {
        async let devices = ProcessRunner.output(lpinfo, ["-l", "-v", "--timeout", "10"], timeout: 30)
        async let configured = ProcessRunner.output(PrinterDirectory.lpstat, ["-v"])
        let configuredURIs = configuredDeviceURIs(inLpstatOutput: await configured ?? "")
        let names = Set(configuredNames.map(normalized))
        return parseDevices(await devices ?? "").filter {
            !configuredURIs.contains($0.uri) && !names.contains(normalized($0.name))
        }
    }

    static func parseDevices(_ output: String) -> [DiscoveredPrinter] {
        var devices: [DiscoveredPrinter] = []
        var fields: [String: String] = [:]

        func flush() {
            if let uri = fields["uri"], uri.contains(":/") {
                devices.append(DiscoveredPrinter(
                    uri: uri,
                    isNetwork: fields["class"] == "network",
                    info: fields["info"] ?? "",
                    makeAndModel: fields["make-and-model"] ?? "",
                    deviceID: fields["device-id"] ?? ""
                ))
            }
            fields = [:]
        }

        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Device:") {
                flush()
                fields["uri"] = trimmed.components(separatedBy: "uri = ").last
            } else if let separator = trimmed.range(of: " = ") {
                fields[String(trimmed[..<separator.lowerBound])] = String(trimmed[separator.upperBound...])
            }
        }
        flush()
        var seen = Set<String>()
        return devices.filter { seen.insert($0.uri).inserted }
    }

    static func configuredDeviceURIs(inLpstatOutput output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            line.range(of: ": ").map { String(line[$0.upperBound...]) }
        })
    }

    static func installedDriver(for printer: DiscoveredPrinter) async -> String? {
        var queries: [[String]] = []
        if !printer.deviceID.isEmpty { queries.append(["--device-id", printer.deviceID, "-m"]) }
        if printer.model != printer.uri { queries.append(["--make-and-model", printer.model, "-m"]) }
        for query in queries {
            guard let output = await ProcessRunner.output(lpinfo, query, timeout: 20) else { continue }
            let drivers = output.split(whereSeparator: \.isNewline)
                .compactMap { $0.split(separator: " ", maxSplits: 1).first.map(String.init) }
                .filter { $0 != "raw" && $0 != "everywhere" }
            if let driver = drivers.first { return driver }
        }
        return nil
    }

    static func add(_ printer: DiscoveredPrinter) async -> Result<Void, PrinterSetupError> {
        guard let queue = await QueueReservations.shared.reserve(for: printer.name) else {
            return .failure(.failed("Couldn’t read this Mac’s printer list"))
        }
        let result = await add(printer, as: queue)
        if case .failure = result { await QueueReservations.shared.release(queue) }
        return result
    }

    private static func add(_ printer: DiscoveredPrinter, as queue: String) async -> Result<Void, PrinterSetupError> {
        var lastError = PrinterSetupError.needsDriver
        var models: [String] = []
        if printer.isDriverless { models.append("everywhere") }
        if let driver = await installedDriver(for: printer) { models.append(driver) }

        for model in models {
            guard let result = await ProcessRunner.run(
                lpadmin,
                ["-p", queue, "-E", "-v", printer.uri, "-m", model, "-D", printer.name],
                timeout: 90
            ) else {
                lastError = .failed("")
                continue
            }
            if result.succeeded { return .success(()) }
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.localizedCaseInsensitiveContains("forbidden") || detail.localizedCaseInsensitiveContains("not authorized") {
                return .failure(.notAuthorized)
            }
            lastError = .failed(detail.replacingOccurrences(of: "lpadmin: ", with: ""))
        }
        return .failure(lastError)
    }

    static func queueName(for name: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let words = name.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        let base = String((words.isEmpty ? ["Printer"] : words).joined(separator: "_").prefix(100))
        var candidate = base
        var suffix = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func configuredQueues() async -> [String]? {
        guard let output = await ProcessRunner.output(PrinterDirectory.lpstat, ["-e"]) else { return nil }
        return output.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

@MainActor
final class QueueReservations {
    static let shared = QueueReservations()
    private var reserved: [String] = []

    func reserve(for name: String) async -> String? {
        guard let configured = await PrinterSetup.configuredQueues() else { return nil }
        let queue = PrinterSetup.queueName(for: name, existing: configured + reserved)
        reserved.append(queue)
        return queue
    }

    func release(_ queue: String) {
        reserved.removeAll { $0 == queue }
    }
}
