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
    case unchecked

    var canPrint: Bool {
        switch self {
        case .online, .ready, .printing, .unchecked: true
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
        case .unchecked: "Can’t check"
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
        let verified = preferred.first { $0.status.canPrint && $0.status != .unchecked }
        return (verified ?? preferred.first(where: \.status.canPrint) ?? preferred.first)?.id ?? currentPrinter
    }
}
