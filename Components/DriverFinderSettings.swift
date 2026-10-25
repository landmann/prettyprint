import SwiftUI

struct DriverFinderSettings: View {
    @State private var routes: [DriverFinderRoute: String] = [:]
    @State private var hasLoaded = false
    @State private var keyDraft = ""
    @State private var keyError: String?
    @AppStorage(DriverFinder.routeDefaultsKey) private var storedRoute = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Driver finder").font(.title2.weight(.semibold))
                Text("When a printer needs a manufacturer driver, an AI model searches the manufacturer’s site for it. Use your own API key or the Claude Code CLI if you’re signed in to it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let savedKeyRoute {
                HStack {
                    Text("\(savedKeyRoute.title) saved in Keychain")
                    Spacer()
                    Button("Remove", role: .destructive) {
                        DriverFinderKey.delete()
                        Task { await reload() }
                    }
                    .buttonStyle(.bordered)
                    .prettyPrintHoverHighlight(.destructive)
                    .prettyPrintButtonCursor()
                }
            } else {
                HStack {
                    SecureField("Anthropic or OpenAI API key", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .buttonStyle(.bordered)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .prettyPrintHoverHighlight(.accent)
                        .prettyPrintButtonCursor()
                }
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.red)
                }
            }
            Text(cliStatus).font(.callout).foregroundStyle(.secondary)
            if availableRoutes.count > 1 {
                LabeledContent("Use") {
                    Picker("Use", selection: Binding(
                        get: { DriverFinder.preferredRoute(in: routes) ?? availableRoutes[0] },
                        set: { storedRoute = $0.rawValue }
                    )) {
                        ForEach(availableRoutes) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    .prettyPrintButtonCursor()
                }
            }
        }
        .task { await reload() }
    }

    private var availableRoutes: [DriverFinderRoute] {
        DriverFinderRoute.allCases.filter { routes[$0] != nil }
    }

    private var savedKeyRoute: DriverFinderRoute? {
        [DriverFinderRoute.anthropic, .openAI].first { routes[$0] != nil }
    }

    private var cliStatus: String {
        guard hasLoaded else { return "Looking for Claude Code…" }
        return routes[.claudeCode] == nil ? "Claude Code CLI not found." : "Found Claude Code."
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard DriverFinderKey.save(key) else {
            keyError = "Couldn’t save the key to Keychain"
            return
        }
        keyDraft = ""
        keyError = nil
        storedRoute = DriverFinderKey.provider(for: key).rawValue
        Task { await reload() }
    }

    private func reload() async {
        routes = await DriverFinder.availableRoutes()
        hasLoaded = true
    }
}
