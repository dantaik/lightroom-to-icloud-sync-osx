import Foundation

/// Decides when the background loop may start an automatic sync pass.
///
/// It only has to answer "is the next check due?". What keeps a pass from running against settings
/// that are still being typed is `SyncSettingsEditor`: the loop reads the saved settings, and the
/// draft in the panel is not saved until the user presses Save.
public struct SyncSchedule: Equatable {
    public var interval: TimeInterval

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    public enum Decision: Equatable {
        case start
        case waitForInterval
    }

    public func decision(now: Date, lastAttempt: Date?) -> Decision {
        guard let lastAttempt else { return .start }
        let elapsed = now.timeIntervalSince(lastAttempt)
        // A negative elapsed time means the clock moved backwards; check now rather than wedge
        // the loop until the clock catches up.
        return (elapsed < 0 || elapsed >= interval) ? .start : .waitForInterval
    }

    public func shouldStart(now: Date, lastAttempt: Date?) -> Bool {
        decision(now: now, lastAttempt: lastAttempt) == .start
    }
}
