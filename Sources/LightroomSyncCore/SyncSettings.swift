import Foundation

/// The unit the check interval is expressed in.
public enum IntervalUnit: String, Codable, CaseIterable, Equatable, Identifiable {
    case minutes
    case hours
    case days

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .minutes: return 60
        case .hours: return 3600
        case .days: return 86_400
        }
    }

    /// What a sensible number of this unit looks like. A day is already a long time to hold a
    /// photo back, so the top of each range is generous rather than unlimited.
    public var range: ClosedRange<Int> {
        switch self {
        case .minutes: return 1...240
        case .hours: return 1...48
        case .days: return 1...30
        }
    }

    public var pluralName: String { rawValue }

    public func name(for value: Int) -> String {
        guard value == 1 else { return pluralName }
        return String(pluralName.dropLast())
    }

    public func clamp(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

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
    /// How often to check, as a number of `intervalUnit`.
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit
    /// How large synced photos are. Full-size renders are slow to move and larger than any
    /// screen, so the default caps them at a Pro Display XDR's width.
    public var photoSize: PhotoSize
    /// How many photos are fetched from Lightroom at once. See ``downloadConcurrencyRange``.
    public var downloadConcurrency: Int

    public static let defaultIntervalValue = 15
    public static let defaultIntervalUnit = IntervalUnit.minutes

    /// Fetching one photo at a time spends nearly all of a check waiting on Lightroom to render
    /// the next one. Five at once keeps that wait overlapped without leaning on Adobe's servers.
    public static let defaultDownloadConcurrency = 5
    /// 1 turns the overlap off, which is how the app behaved before it existed. The top is a
    /// limit on what these undocumented endpoints are asked to do at once, not a target.
    ///
    /// ``URLSessionTransport`` opens its connection limit to the top of this range. URLSession's
    /// own default is 6, which quietly queued anything asked for beyond the sixth: those photos
    /// sat waiting for a connection with their timing clock already running, so the log showed
    /// them as slow downloads rather than as photos that had not started.
    public static let downloadConcurrencyRange = 1...10

    public static func clamp(downloadConcurrency value: Int) -> Int {
        min(max(value, downloadConcurrencyRange.lowerBound), downloadConcurrencyRange.upperBound)
    }

    public static let empty = SyncSettings(shareLink: "", albumID: nil, photosAlbumName: "",
                                           intervalValue: defaultIntervalValue,
                                           intervalUnit: defaultIntervalUnit)

    public init(shareLink: String, albumID: String?, photosAlbumName: String,
                intervalValue: Int, intervalUnit: IntervalUnit, photoSize: PhotoSize = .default,
                downloadConcurrency: Int = SyncSettings.defaultDownloadConcurrency) {
        self.shareLink = shareLink
        self.albumID = albumID
        self.photosAlbumName = photosAlbumName
        self.intervalValue = intervalValue
        self.intervalUnit = intervalUnit
        self.photoSize = photoSize
        self.downloadConcurrency = downloadConcurrency
    }

    /// The form that gets stored and used: trimmed, clamped, with empty text as nil.
    /// Comparing normalized values is what decides whether there is anything to save, so trailing
    /// spaces do not count as an edit.
    public var normalized: SyncSettings {
        SyncSettings(
            shareLink: shareLink.trimmingCharacters(in: .whitespacesAndNewlines),
            albumID: albumID.flatMap { $0.isEmpty ? nil : $0 },
            photosAlbumName: photosAlbumName.trimmingCharacters(in: .whitespacesAndNewlines),
            intervalValue: intervalUnit.clamp(intervalValue),
            intervalUnit: intervalUnit,
            photoSize: photoSize,
            downloadConcurrency: Self.clamp(downloadConcurrency: downloadConcurrency)
        )
    }

    /// Whether these settings name an album to sync. Unconfigured settings keep the loop idle.
    public var isConfigured: Bool {
        !shareLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var checkInterval: TimeInterval {
        let settings = normalized
        return TimeInterval(settings.intervalValue) * settings.intervalUnit.seconds
    }

    /// "15 minutes", "2 hours", "1 day" — for the log and the status text.
    public var intervalDescription: String {
        let settings = normalized
        return "\(settings.intervalValue) \(settings.intervalUnit.name(for: settings.intervalValue))"
    }

    /// Reads an interval stored as plain minutes, which is how the first version saved it, and
    /// picks the largest unit that expresses it exactly: 1440 becomes a day, not 1440 minutes.
    public static func interval(fromMinutes minutes: Int) -> (value: Int, unit: IntervalUnit) {
        guard minutes > 0 else { return (defaultIntervalValue, defaultIntervalUnit) }
        if minutes % (24 * 60) == 0, IntervalUnit.days.range.contains(minutes / (24 * 60)) {
            return (minutes / (24 * 60), .days)
        }
        if minutes % 60 == 0, IntervalUnit.hours.range.contains(minutes / 60) {
            return (minutes / 60, .hours)
        }
        return (IntervalUnit.minutes.clamp(minutes), .minutes)
    }

    public func syncConfiguration(ignoreDelays: Bool) -> SyncConfiguration {
        let settings = normalized
        return SyncConfiguration(shareLink: settings.shareLink,
                                 preferredAlbumID: settings.albumID,
                                 photosAlbumName: settings.photosAlbumName.isEmpty ? nil : settings.photosAlbumName,
                                 checkInterval: settings.checkInterval,
                                 photoSize: settings.photoSize,
                                 ignoreDelays: ignoreDelays,
                                 downloadConcurrency: settings.downloadConcurrency)
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

    /// Switches the unit, keeping the number inside what the new unit allows.
    public mutating func setIntervalUnit(_ unit: IntervalUnit) {
        draft.intervalValue = unit.clamp(draft.intervalValue)
        draft.intervalUnit = unit
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
