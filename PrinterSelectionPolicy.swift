enum Status: Equatable {
    case checking
    case online
    case ready
    case printing
    case paperNeeded
    case paused
    case attention
    case unavailable
    case offline

    var canPrint: Bool {
        switch self {
        case .online, .ready, .printing: true
        case .checking, .paperNeeded, .paused, .attention, .unavailable, .offline: false
        }
    }

    var title: String {
        switch self {
        case .checking: "Checking"
        case .online: "Online"
        case .ready: "Ready"
        case .printing: "Printing"
        case .paperNeeded: "Load paper"
        case .paused: "Paused"
        case .attention: "Check printer"
        case .unavailable: "Unavailable"
        case .offline: "Offline"
        }
    }
}

enum PrinterSelectionPolicy {
    static func automaticSelection(
        currentPrinter: String,
        printers: [Printer],
        defaultPrinterID: String?,
        hasManualPrinterSelection: Bool
    ) -> String {
        if hasManualPrinterSelection, printers.contains(where: { $0.id == currentPrinter }) {
            return currentPrinter
        }
        let preferred = printers.filter { $0.id == defaultPrinterID } + printers.filter { $0.id != defaultPrinterID }
        return preferred.first(where: \.status.canPrint)?.id ?? preferred.first?.id ?? currentPrinter
    }
}
