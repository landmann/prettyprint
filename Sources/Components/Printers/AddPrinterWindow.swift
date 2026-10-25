import AppKit
import SwiftUI

@MainActor
final class AddPrinterPresenter: NSObject, NSWindowDelegate {
    static let shared = AddPrinterPresenter()
    private var window: NSWindow?
    private var model: AddPrinterModel?
    private var keyMonitor: Any?

    func show(onAdded: @escaping () -> Void) {
        if let window, let model {
            model.onAdded = onAdded
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = AddPrinterModel(onAdded: onAdded)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Add printer"
        window.minSize = NSSize(width: 440, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: AddPrinterView(model: model))
        window.center()
        self.window = window
        self.model = model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, event.window === window, window.isKeyWindow, NSApp.modalWindow == nil,
                  let press = PrettyPrintKeyPress(event),
                  PrettyPrintShortcuts.shared.action(for: press, in: .settings) == .close else { return event }
            window.close()
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.search()
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model?.close()
        model = nil
        window = nil
    }
}

@MainActor
final class AddPrinterModel: ObservableObject {
    enum RowState: Equatable {
        case idle
        case adding
        case added
        case needsDriver
        case findingDriver
        case suggestion(DriverSuggestion)
        case downloading(DriverSuggestion)
        case verified(DriverSuggestion, VerifiedDriverPackage)
        case manualInstall(DriverSuggestion)
        case installing
        case failed(String)
    }

    @Published private(set) var isSearching = false
    @Published private(set) var printers: [DiscoveredPrinter] = []
    @Published private(set) var states: [DiscoveredPrinter.ID: RowState] = [:]
    @Published private(set) var canFindDrivers = false
    var onAdded: () -> Void
    private var isClosed = false
    private var downloads: [DiscoveredPrinter.ID: UUID] = [:]

    init(onAdded: @escaping () -> Void) {
        self.onAdded = onAdded
    }

    func state(of printer: DiscoveredPrinter) -> RowState {
        states[printer.id] ?? .idle
    }

    func search() {
        guard !isSearching else { return }
        isSearching = true
        Task {
            async let routes = DriverFinder.availableRoutes()
            let configured = await PrinterDirectory.load().printers
            let found = await PrinterSetup.discover(excludingNames: configured.map(\.name))
            for (id, state) in states where !found.contains(where: { $0.id == id }) {
                if case .verified(_, let package) = state { DriverInstaller.discard(package) }
                states[id] = nil
                downloads[id] = nil
            }
            printers = found
            canFindDrivers = !(await routes).isEmpty
            isSearching = false
        }
    }

    func add(_ printer: DiscoveredPrinter) {
        states[printer.id] = .adding
        Task {
            switch await PrinterSetup.add(printer) {
            case .success:
                states[printer.id] = .added
                onAdded()
            case .failure(.needsDriver):
                canFindDrivers = !(await DriverFinder.availableRoutes()).isEmpty
                states[printer.id] = .needsDriver
            case .failure(let error):
                states[printer.id] = .failed(error.message)
            }
        }
    }

    func findDriver(for printer: DiscoveredPrinter) {
        states[printer.id] = .findingDriver
        Task {
            switch await DriverFinder.find(for: printer) {
            case .success(let suggestion) where suggestion.found:
                states[printer.id] = .suggestion(suggestion)
            case .success:
                states[printer.id] = .failed("No macOS driver found for this printer")
            case .failure(let error):
                states[printer.id] = .failed(error.message)
            }
        }
    }

    func download(_ suggestion: DriverSuggestion, for printer: DiscoveredPrinter) {
        guard let source = suggestion.packageURL.flatMap(URL.init(string:)) else {
            if let page = URL(string: suggestion.pageURL) { NSWorkspace.shared.open(page) }
            states[printer.id] = .manualInstall(suggestion)
            return
        }
        states[printer.id] = .downloading(suggestion)
        let operation = UUID()
        downloads[printer.id] = operation
        Task {
            let result = await DriverInstaller.prepare(from: source)
            guard !isClosed, downloads[printer.id] == operation else {
                if case .success(let package) = result { DriverInstaller.discard(package) }
                return
            }
            downloads[printer.id] = nil
            switch result {
            case .success(let package): states[printer.id] = .verified(suggestion, package)
            case .failure(let error): states[printer.id] = .failed(error.message)
            }
        }
    }

    func install(_ package: VerifiedDriverPackage, for printer: DiscoveredPrinter) {
        states[printer.id] = .installing
        Task {
            switch await DriverInstaller.install(package) {
            case .success: add(printer)
            case .failure(let error): states[printer.id] = .failed(error.message)
            }
        }
    }

    func close() {
        isClosed = true
        for case .verified(_, let package) in states.values { DriverInstaller.discard(package) }
    }
}

private struct AddPrinterView: View {
    @ObservedObject var model: AddPrinterModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.isSearching && model.printers.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Searching for printers…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.printers.isEmpty {
                    Text("No printers found nearby. Turn the printer on, connect it to this Wi‑Fi network or by USB, then search again.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 320)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.printers) { printer in
                                row(printer)
                                Divider()
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Printers & Scanners") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.printfax") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .prettyPrintHoverHighlight(.accent)
                .prettyPrintButtonCursor()
                Spacer()
                Button(action: model.search) {
                    Text(model.isSearching ? "Searching…" : "Search again")
                }
                .buttonStyle(.bordered)
                .disabled(model.isSearching)
                .prettyPrintHoverHighlight(.accent)
                .prettyPrintButtonCursor()
            }
            .frame(minHeight: 42)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ printer: DiscoveredPrinter) -> some View {
        let state = model.state(of: printer)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: printer.isNetwork ? "wifi" : "cable.connector")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityLabel(printer.isNetwork ? "Network" : "USB")
                VStack(alignment: .leading, spacing: 2) {
                    Text(printer.name).lineLimit(1)
                    if printer.model != printer.name {
                        Text(printer.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailingControl(printer, state: state)
            }
            detail(printer, state: state)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func trailingControl(_ printer: DiscoveredPrinter, state: AddPrinterModel.RowState) -> some View {
        switch state {
        case .idle:
            actionButton("Add", prominent: true) { model.add(printer) }
        case .adding, .findingDriver, .downloading, .installing:
            ProgressView().controlSize(.small)
        case .added:
            Label("Added", systemImage: "checkmark").foregroundStyle(.green)
        case .needsDriver:
            if model.canFindDrivers {
                actionButton("Find driver", prominent: true) { model.findDriver(for: printer) }
            } else {
                actionButton("Set up driver finder", prominent: false) { PrettyPrintSettingsPresenter.shared.show() }
            }
        case .suggestion(let suggestion):
            actionButton(suggestion.packageURL == nil ? "Open download page" : "Download", prominent: true) {
                model.download(suggestion, for: printer)
            }
        case .verified(_, let package):
            actionButton("Open installer", prominent: true) { model.install(package, for: printer) }
        case .manualInstall:
            actionButton("Add", prominent: true) { model.add(printer) }
        case .failed:
            actionButton("Try again", prominent: false) { model.add(printer) }
        }
    }

    @ViewBuilder
    private func detail(_ printer: DiscoveredPrinter, state: AddPrinterModel.RowState) -> some View {
        switch state {
        case .adding:
            caption("Adding…")
        case .needsDriver:
            caption("This printer needs a driver from its manufacturer.")
        case .findingDriver:
            caption("Searching the manufacturer’s site for a driver…")
        case .suggestion(let suggestion), .downloading(let suggestion):
            suggestionCard(suggestion, status: state == .downloading(suggestion) ? "Downloading…" : nil)
        case .verified(let suggestion, let package):
            suggestionCard(suggestion, status: "Signed by \(DriverInstaller.displayName(of: package.signingIdentity)) and notarized by Apple")
        case .manualInstall(let suggestion):
            suggestionCard(suggestion, status: "Install the driver from the manufacturer’s page, then click Add.")
        case .installing:
            caption("Finish installing. PrettyPrint adds the printer when the installer quits.")
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.leading, 30)
        case .idle, .added:
            EmptyView()
        }
    }

    private func suggestionCard(_ suggestion: DriverSuggestion, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(suggestion.vendor) \(suggestion.driverName)").font(.callout.weight(.medium))
            if !suggestion.notes.isEmpty {
                Text(suggestion.notes).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let page = URL(string: suggestion.pageURL), let host = page.host() {
                Link(host, destination: page).font(.caption).prettyPrintButtonCursor()
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.leading, 30)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
    }

    @ViewBuilder
    private func actionButton(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .prettyPrintHoverHighlight(.primary)
                .prettyPrintButtonCursor()
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .prettyPrintHoverHighlight(.accent)
                .prettyPrintButtonCursor()
        }
    }
}
