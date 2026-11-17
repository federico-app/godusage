import Foundation

extension WidgetData {
    /// From this share used (rounded to the headline's whole percent), a bar is red: the absolute
    /// critical band, and the point where a projected run-out counts as nearly reached.
    static let criticalPercentUsed: Double = 90

    /// The meter's fill color for `state`, or `nil` for `noData` (the track stays gray).
    ///
    /// Red is kept for a limit that is reached or nearly reached: `spent`, and a run-out projection
    /// once the share used is in the critical band. A run-out that is only projected, with plenty
    /// still left, is orange (`atRisk`), so a bar reading "Limit in 3d 17h" doesn't look as alarming
    /// as one that is empty. Yellow is cutting it close, blue on course.
    func meterSeverity(for state: MeterState) -> MeterSeverity? {
        switch state {
        case .noData: return nil
        case .spent: return .critical
        case .runningOut: return isNearlySpent ? .critical : .atRisk
        case .closeToLimit: return .warning
        case .healthy: return .normal
        case .level(let severity): return severity
        }
    }

    /// The share used is in the critical band, at the headline's whole-percent rounding.
    private var isNearlySpent: Bool {
        guard let limit, limit > 0 else { return false }
        return (min(max(used / limit, 0), 1) * 100).rounded() >= Self.criticalPercentUsed
    }
}
