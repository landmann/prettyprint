import AppKit
import Combine

@MainActor
final class FileRenameCoordinator: ObservableObject {
    static let shared = FileRenameCoordinator()
    @Published private(set) var revision = 0

    private let stager = PrettyPrintDocumentStager()
    private var names: [URL: String] = [:]

    func displayName(for url: URL) -> String {
        if let name = names[url] { return name }
        let name = (stager.originalURL(for: url) ?? url).lastPathComponent
        names[url] = name
        return name
    }

    func rename(_ stagedURL: URL, relativeTo window: NSWindow?) {
        let previousLevel = window?.level
        window?.level = .normal
        defer {
            if let previousLevel {
                window?.level = previousLevel
                window?.makeKeyAndOrderFront(nil)
            }
        }

        guard let original = stager.originalURL(for: stagedURL),
              FileManager.default.fileExists(atPath: original.path) else {
            showError("Add this file again to rename the original", detail: "PrettyPrint needs the original file's location.")
            return
        }

        let input = NSTextField(string: original.lastPathComponent)
        input.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        input.setAccessibilityLabel("File name")
        let alert = NSAlert()
        alert.messageText = "This will rename the global file"
        alert.informativeText = original.path
        alert.alertStyle = .warning
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input

        while PrettyPrintShortcuts.shared.runModal(alert) == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
                showError("Enter a valid file name", detail: "Use a name without slashes or colons.")
                continue
            }
            let destination = original.deletingLastPathComponent().appendingPathComponent(name)
            if destination == original { return }
            do {
                try FileManager.default.moveItem(at: original, to: destination)
                try? stager.rememberOriginal(destination, for: stagedURL)
                names.removeAll()
                names[stagedURL] = name
                revision += 1
                return
            } catch {
                showError("Couldn’t rename the file", detail: error.localizedDescription)
            }
        }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        PrettyPrintShortcuts.shared.runModal(alert)
    }
}
