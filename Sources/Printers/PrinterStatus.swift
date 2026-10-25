enum PrinterStatus: Equatable {
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
        case .unavailable: "Not available"
        case .offline: "Offline"
        }
    }
}
