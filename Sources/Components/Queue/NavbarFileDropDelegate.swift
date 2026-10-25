import SwiftUI
import UniformTypeIdentifiers

struct NavbarFileDropDelegate: DropDelegate {
    let onTargeted: (Int) -> Void
    let onExited: () -> Void
    let onPerform: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        !providers(from: info).isEmpty
    }

    func dropEntered(info: DropInfo) {
        updateTarget(with: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(with: info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        onExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = providers(from: info)
        onExited()
        guard !providers.isEmpty else { return false }
        return onPerform(providers)
    }

    private func updateTarget(with info: DropInfo) {
        onTargeted(providers(from: info).count)
    }

    private func providers(from info: DropInfo) -> [NSItemProvider] {
        info.itemProviders(for: [.fileURL])
    }
}
