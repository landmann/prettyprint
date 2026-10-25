import Foundation
import Security

struct DriverSuggestion: Codable, Equatable {
    let found: Bool
    let vendor: String
    let driverName: String
    let pageURL: String
    let packageURL: String?
    let notes: String
}

enum DriverFinderRoute: String, CaseIterable, Identifiable {
    case anthropic, openAI, claudeCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anthropic: "Anthropic API key"
        case .openAI: "OpenAI API key"
        case .claudeCode: "Claude Code"
        }
    }
}

enum DriverFinderError: Error, Equatable {
    case notConfigured
    case failed(String)
    case unreadableAnswer

    var message: String {
        switch self {
        case .notConfigured: "Set up the driver finder in Settings"
        case .failed(let detail): detail
        case .unreadableAnswer: "The driver finder didn’t return a driver"
        }
    }
}

enum DriverFinderKey {
    private static let service = "io.github.landmann.prettyprint"
    private static let account = "driver-finder-api-key"

    static func provider(for key: String) -> DriverFinderRoute {
        key.hasPrefix("sk-ant-") ? .anthropic : .openAI
    }

    static func load() -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        return SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(key.utf8),
        ] as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }
}

enum DriverFinder {
    static let routeDefaultsKey = "driverFinderRoute"
    private static let anthropicModel = "claude-opus-5-5"
    private static let openAIModel = "gpt-6-astra"
    private static let lookupTimeout: TimeInterval = 240

    static func availableRoutes() async -> [DriverFinderRoute: String] {
        var routes: [DriverFinderRoute: String] = [:]
        if let key = DriverFinderKey.load() { routes[DriverFinderKey.provider(for: key)] = key }
        if let path = await executablePath(named: "claude") { routes[.claudeCode] = path }
        return routes
    }

    static func preferredRoute(in routes: [DriverFinderRoute: String]) -> DriverFinderRoute? {
        let stored = UserDefaults.standard.string(forKey: routeDefaultsKey).flatMap(DriverFinderRoute.init(rawValue:))
        if let stored, routes[stored] != nil { return stored }
        return DriverFinderRoute.allCases.first { routes[$0] != nil }
    }

    static func find(for printer: DiscoveredPrinter) async -> Result<DriverSuggestion, DriverFinderError> {
        let routes = await availableRoutes()
        guard let route = preferredRoute(in: routes), let credential = routes[route] else {
            return .failure(.notConfigured)
        }
        let prompt = prompt(for: printer)
        let answer: Result<String, DriverFinderError>
        switch route {
        case .anthropic: answer = await askAnthropic(prompt, key: credential)
        case .openAI: answer = await askOpenAI(prompt, key: credential)
        case .claudeCode: answer = await askClaudeCode(prompt, executable: credential)
        }
        return answer.flatMap { text in
            guard let suggestion = parse(text) else { return .failure(.unreadableAnswer) }
            return .success(suggestion)
        }
    }

    static func prompt(for printer: DiscoveredPrinter) -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let cpu = "Apple silicon (arm64)"
        #else
        let cpu = "Intel (x86_64)"
        #endif
        return """
        Find the official macOS printer driver for this printer.

        Printer name: \(printer.name)
        Make and model: \(printer.model)
        IEEE 1284 device ID: \(printer.deviceID.isEmpty ? "unknown" : printer.deviceID)
        Connection URI scheme: \(printer.uri.prefix { $0 != ":" })
        macOS version: \(version.majorVersion).\(version.minorVersion)
        CPU: \(cpu)

        Search the web. Use only the manufacturer's own website or Apple's support site. The driver must support this macOS version on this CPU. Prefer a direct https link to the installer package (.pkg, .dmg, or .zip) hosted by the manufacturer; leave packageURL null when you can only find the download page.

        Reply with only this JSON object and no other text:
        {"found": true or false, "vendor": "...", "driverName": "...", "pageURL": "https://...", "packageURL": "https://..." or null, "notes": "one short sentence for the user"}
        """
    }

    static func parse(_ text: String) -> DriverSuggestion? {
        var candidate = text[...]
        while let start = candidate.firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaping = false
            for index in candidate[start...].indices {
                let character = candidate[index]
                if escaping { escaping = false; continue }
                if character == "\\" { escaping = inString; continue }
                if character == "\"" { inString.toggle(); continue }
                guard !inString else { continue }
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let json = Data(candidate[start...index].utf8)
                        if let suggestion = try? JSONDecoder().decode(DriverSuggestion.self, from: json) {
                            return validated(suggestion)
                        }
                        break
                    }
                }
            }
            candidate = candidate[candidate.index(after: start)...]
        }
        return nil
    }

    private static func validated(_ suggestion: DriverSuggestion) -> DriverSuggestion? {
        guard !suggestion.found || URL(string: suggestion.pageURL)?.scheme == "https" else { return nil }
        let packageURL = suggestion.packageURL.flatMap { URL(string: $0)?.scheme == "https" ? $0 : nil }
        return DriverSuggestion(
            found: suggestion.found,
            vendor: suggestion.vendor,
            driverName: suggestion.driverName,
            pageURL: suggestion.pageURL,
            packageURL: packageURL,
            notes: suggestion.notes
        )
    }

    private static func askAnthropic(_ prompt: String, key: String) async -> Result<String, DriverFinderError> {
        var messages: [[String: Any]] = [["role": "user", "content": prompt]]
        for _ in 0..<3 {
            let body: [String: Any] = [
                "model": anthropicModel,
                "max_tokens": 16000,
                "output_config": ["effort": "low"],
                "fallbacks": "default",
                "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": 5]],
                "messages": messages,
            ]
            let response = await post(
                "https://api.anthropic.com/v1/messages",
                body: body,
                headers: [
                    "x-api-key": key,
                    "anthropic-version": "2023-06-01",
                    "anthropic-beta": "server-side-fallback-2026-07-01",
                ]
            )
            guard case .success(let json) = response else { return response.map { _ in "" } }
            let content = json["content"] as? [[String: Any]] ?? []
            switch json["stop_reason"] as? String {
            case "pause_turn":
                messages.append(["role": "assistant", "content": content])
            case "refusal":
                return .failure(.failed("The model declined this lookup"))
            default:
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                return .success(text)
            }
        }
        return .failure(.unreadableAnswer)
    }

    private static func askOpenAI(_ prompt: String, key: String) async -> Result<String, DriverFinderError> {
        let response = await post(
            "https://api.openai.com/v1/responses",
            body: ["model": openAIModel, "tools": [["type": "web_search"]], "input": prompt],
            headers: ["Authorization": "Bearer \(key)"]
        )
        return response.map { json in
            (json["output"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }
                .joined()
        }
    }

    private static func askClaudeCode(_ prompt: String, executable: String) async -> Result<String, DriverFinderError> {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = await ProcessRunner.run(
            executable,
            [
                "-p", "--safe-mode", "--output-format", "json",
                "--tools=WebSearch,WebFetch", "--allowedTools=WebSearch,WebFetch",
                "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
            ],
            timeout: lookupTimeout,
            environment: environment(for: executable),
            currentDirectory: directory,
            input: Data(prompt.utf8)
        )
        guard let result, result.succeeded,
              let json = try? JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any],
              json["is_error"] as? Bool != true,
              let text = json["result"] as? String else {
            return .failure(.failed(cliFailure(result)))
        }
        return .success(text)
    }

    private static func cliFailure(_ result: ProcessOutput?) -> String {
        guard let result else { return "Claude Code didn’t finish" }
        let detail = result.standardError.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return detail.isEmpty ? "Claude Code failed. Check that it’s signed in." : "Claude Code: \(detail)"
    }

    private static func post(
        _ url: String,
        body: [String: Any],
        headers: [String: String]
    ) async -> Result<[String: Any], DriverFinderError> {
        guard let url = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.unreadableAnswer)
        }
        var request = URLRequest(url: url, timeoutInterval: lookupTimeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] ?? [:]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let error = json["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "Request failed (\(status))"
                return .failure(.failed(status == 401 ? "The API key was rejected" : message))
            }
            return .success(json)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }

    private static func environment(for executable: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = [directory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""]
            .joined(separator: ":")
        return environment
    }

    private static func executablePath(named name: String) async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)", "\(home)/.claude/local/\(name)",
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.npm-global/bin/\(name)",
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile) { return path }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = await ProcessRunner.output(shell, ["-l", "-i", "-c", "whence -p \(name) || command -v \(name)"], timeout: 5) else {
            return nil
        }
        return output.split(whereSeparator: \.isNewline).map(String.init).last {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
