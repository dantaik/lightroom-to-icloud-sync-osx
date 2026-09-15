import Foundation

/// Decides when the background loop may start an automatic sync pass.
///
/// The settle time matters as much as the interval: the settings panel writes every keystroke
/// straight to the model, so without it a pass could start while an album name is half typed and
/// file the photos into an album called `Lightroo`.
public struct SyncSchedule: Equatable {
    public var interval: TimeInterval
    /// How long the settings must stay untouched before an automatic pass may start.
    public var settingsSettleTime: TimeInterval

    public static let defaultSettingsSettleTime: TimeInterval = 8

    public init(interval: TimeInterval, settingsSettleTime: TimeInterval = SyncSchedule.defaultSettingsSettleTime) {
        self.interval = interval
        self.settingsSettleTime = settingsSettleTime
    }

    public enum Decision: Equatable {
        case start
        case waitForSettings
        case waitForInterval
    }

    public func decision(now: Date, lastAttempt: Date?, lastSettingsChange: Date?) -> Decision {
        if let lastSettingsChange {
            let idle = now.timeIntervalSince(lastSettingsChange)
            if idle >= 0, idle < settingsSettleTime { return .waitForSettings }
        }
        guard let lastAttempt else { return .start }
        return now.timeIntervalSince(lastAttempt) >= interval ? .start : .waitForInterval
    }

    public func shouldStart(now: Date, lastAttempt: Date?, lastSettingsChange: Date?) -> Bool {
        decision(now: now, lastAttempt: lastAttempt, lastSettingsChange: lastSettingsChange) == .start
    }
}
