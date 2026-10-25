import AppKit

@MainActor
protocol PopoverFilePickerPresentation: AnyObject {
    func closePopover()
    func activateApplication()
    func showPopover()
}

enum FilePickerResponse {
    case ok([URL])
    case cancel
}

@MainActor
protocol FilePicking {
    func runModal() -> FilePickerResponse
}

@MainActor
final class PopoverFilePickerCoordinator {
    private let presentation: PopoverFilePickerPresentation
    private let makePicker: @MainActor () -> FilePicking

    init(
        presentation: PopoverFilePickerPresentation,
        makePicker: @escaping @MainActor () -> FilePicking = { AppKitFilePicker() }
    ) {
        self.presentation = presentation
        self.makePicker = makePicker
    }

    func chooseFiles() -> [URL] {
        presentation.closePopover()
        presentation.activateApplication()

        let result = makePicker().runModal()

        presentation.showPopover()

        switch result {
        case .ok(let urls):
            return urls
        case .cancel:
            return []
        }
    }
}

@MainActor
final class AppKitFilePicker: FilePicking {
    private let panel: NSOpenPanel

    init(panel: NSOpenPanel? = nil) {
        let panel = panel ?? NSOpenPanel()
        self.panel = panel
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
    }

    func runModal() -> FilePickerResponse {
        guard panel.runModal() == .OK else {
            return .cancel
        }
        return .ok(panel.urls)
    }
}
