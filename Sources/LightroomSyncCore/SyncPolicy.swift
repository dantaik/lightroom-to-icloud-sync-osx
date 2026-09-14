import Foundation

/// Decides whether a photo in the album is ready to be synced.
///
/// Rules:
/// 1. A photo becomes eligible once it has been in the album for at least `minimumAgeInAlbum`
///    (the configured check interval), which leaves time to make the first edits.
/// 2. A photo edited within the last `settleTime` waits, so an edit in progress is not captured half-done.
/// 3. `ignoreDelays` (the "Sync now" button) skips both rules.
public struct SyncPolicy: Equatable {
    public var minimumAgeInAlbum: TimeInterval
    public var settleTime: TimeInterval
    public var ignoreDelays: Bool

    public static let defaultSettleTime: TimeInterval = 120

    public init(minimumAgeInAlbum: TimeInterval, settleTime: TimeInterval = SyncPolicy.defaultSettleTime, ignoreDelays: Bool = false) {
        self.minimumAgeInAlbum = minimumAgeInAlbum
        self.settleTime = settleTime
        self.ignoreDelays = ignoreDelays
    }

    public enum Decision: Equatable {
        case sync
        case wait(String)
    }

    public func decision(for photo: LightroomPhoto, firstSeen: Date, now: Date) -> Decision {
        if ignoreDelays { return .sync }
        let added = photo.addedToAlbumAt ?? firstSeen
        let age = now.timeIntervalSince(added)
        if age < minimumAgeInAlbum {
            let remaining = max(0, minimumAgeInAlbum - age)
            return .wait("added \(Self.minutes(age)) min ago, eligible in \(Self.minutes(remaining, roundUp: true)) min")
        }
        if let edited = photo.lastEditedAt {
            let sinceEdit = now.timeIntervalSince(edited)
            if sinceEdit >= 0, sinceEdit < settleTime {
                return .wait("edited \(Int(sinceEdit)) s ago, waiting for edits to settle")
            }
        }
        return .sync
    }

    private static func minutes(_ interval: TimeInterval, roundUp: Bool = false) -> Int {
        let value = interval / 60
        return Int(roundUp ? value.rounded(.up) : value.rounded(.down))
    }
}
