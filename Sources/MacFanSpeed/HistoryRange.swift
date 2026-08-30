import Foundation

/// How much history the charts show.
enum HistoryRange: Int, CaseIterable, Identifiable {
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30
    case oneHour = 60
    case sixHours = 360

    var id: Int { rawValue }
    static let defaultMinutes = HistoryRange.tenMinutes.rawValue

    /// Longest range offered. The sample buffer is sized for this, so switching
    /// range never has to go and fetch history that was not kept.
    static var maximumMinutes: Int { allCases.map(\.rawValue).max() ?? 10 }

    var label: String {
        switch self {
        case .fiveMinutes:   return "5m"
        case .tenMinutes:    return "10m"
        case .thirtyMinutes: return "30m"
        case .oneHour:       return "1h"
        case .sixHours:      return "6h"
        }
    }

    var caption: String {
        switch self {
        case .fiveMinutes:   return "last 5 minutes"
        case .tenMinutes:    return "last 10 minutes"
        case .thirtyMinutes: return "last 30 minutes"
        case .oneHour:       return "last hour"
        case .sixHours:      return "last 6 hours"
        }
    }

    static func from(minutes: Int) -> HistoryRange {
        allCases.first { $0.rawValue == minutes } ?? .tenMinutes
    }
}
