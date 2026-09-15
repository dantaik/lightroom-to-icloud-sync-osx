import Foundation

/// The settings a sync pass runs on.
///
/// The panel edits a draft of this; only the copy the user has saved drives the background loop,
/// so nothing can run against a half-typed album name or a link that is still being pasted.
public struct SyncSettings: Equatable, Codable {
    public var shareLink: String
    /// Which album of the share to sync, when the share holds more than one.
    public var albumID: String?
    /// Photos album to file synced photos into. Empty means the library only.
    public var photosAlbumName: String
    public var intervalMinutes: Int

    public static let defaultIntervalMinutes = 15
    public static let intervalRange = 1...1440

    public static let empty = SyncSettings(shareLink: "", albumID: nil, photosAlbumName: "",
                                           intervalMinutes: defaultIntervalMinutes)

    public init(shareLink: String, albumID: String?, photosAlbumName: String, intervalMinutes: Int) {
        self.shareLink = shareLink
        self.albumID = albumID
        self.photosAlbumName = photosAlbumName
        self.intervalMinutes = intervalMinutes
    }

    /// The form that gets stored and used: trimmed, clamped, with empty text as nil.
    /// Comparing normalized values is what decides whether there is anything to save, so trailing
    /// spaces do not count as an edit.
    public var normalized: SyncSettings {
        SyncSettings(
            shareLink: shareLink.trimmingCharacters(in: .whitespacesAndNewlines),
            albumID: albumID.flatMap { $0.isEmpty ? nil : $0 },
            photosAlbumName: photosAlbumName.trimmingCharacters(in: .whitespacesAndNewlines),
            intervalMinutes: min(max(intervalMinutes, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
        )
    }

    /// Whether these settings name an album to sync. Unconfigured settings keep the loop idle.
    public var isConfigured: Bool {
        !shareLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var checkInterval: TimeInterval {
        TimeInterval(normalized.intervalMinutes * 60)
    }

    public func syncConfiguration(ignoreDelays: Bool) -> SyncConfiguration {
        let settings = normalized
        return SyncConfiguration(shareLink: settings.shareLink,
                                 preferredAlbumID: settings.albumID,
                                 photosAlbumName: settings.photosAlbumName.isEmpty ? nil : settings.photosAlbumName,
                                 checkInterval: settings.checkInterval,
                                 ignoreDelays: ignoreDelays)
    }
}

/// Where saved settings live between launches.
public protocol SyncSettingsStore {
    /// The saved settings, or nil when the user has never saved any.
    func load() -> SyncSettings?
    func save(_ settings: SyncSettings)
}

/// Holds the edited draft next to the saved settings and says what may act on them.
public struct SyncSettingsEditor: Equatable {
    /// What the panel is editing. Nothing reads this except the panel.
    public var draft: SyncSettings
    /// What the background loop and "Sync now" use. Nil until the user saves for the first time.
    public private(set) var saved: SyncSettings?

    public init(saved: SyncSettings?) {
        self.saved = saved
        self.draft = saved ?? .empty
    }

    public var hasUnsavedChanges: Bool {
        draft.normalized != (saved ?? .empty)
    }

    /// True when a pass may start: the settings are saved, name an album, and are not being edited.
    public var isReadyToSync: Bool {
        guard let saved, saved.isConfigured else { return false }
        return !hasUnsavedChanges
    }

    /// Commits the draft. Returns the settings that were saved, so the caller can store them.
    @discardableResult
    public mutating func save() -> SyncSettings {
        let settings = draft.normalized
        draft = settings
        saved = settings
        return settings
    }

    /// Throws the draft away and goes back to the saved settings.
    public mutating func revert() {
        draft = saved ?? .empty
    }
}
