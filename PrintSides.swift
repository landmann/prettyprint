import Foundation

enum PrintSides: String, CaseIterable, Identifiable, Equatable {
    case oneSided
    case longEdge
    case shortEdge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneSided: "One-sided"
        case .longEdge: "Two-sided, long edge"
        case .shortEdge: "Two-sided, short edge"
        }
    }

    var cupsValue: String {
        switch self {
        case .oneSided: "one-sided"
        case .longEdge: "two-sided-long-edge"
        case .shortEdge: "two-sided-short-edge"
        }
    }
}
