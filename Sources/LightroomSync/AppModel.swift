#if os(macOS)
import AppKit
import Foundation
import LightroomSyncCore
import SwiftUI

/// Forwards engine events onto the main actor.
private final class EventBridge: SyncEventSink {
    weak var model: AppModel?
    let fileLog: FileLog

    init(fileLog: FileLog) {
        self.fileLog = fileLog
    }

    func log(_ level: LogLevel, _ message: String) {
        fileLog.append(level == .info ? message : "[\(level.rawValue)] \(message)")
    }

    func progress(completed: Int, total: Int) {
        let model = self.model
        Task { @MainActor in model?.updateProgress(completed: completed, total: total) }
    }
}

/// Saved settings live in UserDefaults, under the keys the first version used.
private struct UserDefaultsSettingsStore: SyncSettingsStore {
    private enum Keys {
        static let shareLink = "shareLink"
        static let albumID = "selectedAlbumID"
        static let photosAlbum = "photosAlbumName"
        static let intervalValue = "intervalValue"
        static let intervalUnit = "intervalUnit"
        static let photoSize = "photoSize"
        static let downloadConcurrency = "downloadConcurrency"
        static let legacyIntervalMinutes = "intervalMinutes"
    }

    let defaults: UserDefaults

    func load() -> SyncSettings? {
        // No share link key at all means the user has never saved anything.
        guard let shareLink = defaults.string(forKey: Keys.shareLink) else { return nil }
        let interval = loadInterval()
        return SyncSettings(
            shareLink: shareLink,
            albumID: defaults.string(forKey: Keys.albumID),
            photosAlbumName: defaults.string(forKey: Keys.photosAlbum) ?? "",
            intervalValue: interval.value,
            intervalUnit: interval.unit,
            // Settings saved before sizes existed name none, and get the default: photos no
            // larger than a Pro Display XDR rather than the full-size render they used to get.
            photoSize: defaults.string(forKey: Keys.photoSize).flatMap(PhotoSize.init(rawValue:)) ?? .default,
            // Absent (0) in settings saved before photos were fetched several at a time, and
            // `normalized` clamps anything odd back into range.
            downloadConcurrency: loadDownloadConcurrency()
        ).normalized
    }

    /// Reads how many photos to fetch at once, defaulting for settings saved before it existed.
    private func loadDownloadConcurrency() -> Int {
        let stored = defaults.integer(forKey: Keys.downloadConcurrency)
        return stored > 0 ? stored : SyncSettings.defaultDownloadConcurrency
    }

    /// Reads the interval, falling back to the plain minutes the first version stored.
    private func loadInterval() -> (value: Int, unit: IntervalUnit) {
        let value = defaults.integer(forKey: Keys.intervalValue)
        if value > 0, let raw = defaults.string(forKey: Keys.intervalUnit),
           let unit = IntervalUnit(rawValue: raw) {
            return (value, unit)
        }
        return SyncSettings.interval(fromMinutes: defaults.integer(forKey: Keys.legacyIntervalMinutes))
    }

    func save(_ settings: SyncSettings) {
        defaults.set(settings.shareLink, forKey: Keys.shareLink)
        defaults.set(settings.albumID, forKey: Keys.albumID)
        defaults.set(settings.photosAlbumName, forKey: Keys.photosAlbum)
        defaults.set(settings.intervalValue, forKey: Keys.intervalValue)
        defaults.set(settings.intervalUnit.rawValue, forKey: Keys.intervalUnit)
        defaults.set(settings.photoSize.rawValue, forKey: Keys.photoSize)
        defaults.set(settings.downloadConcurrency, forKey: Keys.downloadConcurrency)
        defaults.removeObject(forKey: Keys.legacyIntervalMinutes)
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case syncing(completed: Int, total: Int)
        case failed(String)
    }

    /// What the panel shows next to the share link field.
    enum LinkStatus: Equatable {
        case unknown
        case checking
        case ok
        case problem
    }

    /// Drives the one indicator in the header.
    enum StatusKind: Equatable {
        case unconfigured
        case unsaved
        case syncing
        case failed
        case ok
    }

    /// The settings being edited. Only `editor.saved` drives syncing.
    @Published var editor: SyncSettingsEditor
    @Published private(set) var launchAtLogin = false

    // MARK: Runtime state

    @Published private(set) var shareInfo: ShareInfo?
    @Published private(set) var shareStatus = ""
    @Published private(set) var linkStatus: LinkStatus = .unknown
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastReport: SyncReport?
    @Published private(set) var syncedCount = 0
    @Published private(set) var setupError: String?
    /// Which frame of the menu bar spinner is showing.
    @Published private(set) var spinnerFrame = 0

    let logFileURL: URL

    private let store: SyncSettingsStore
    private let client: LightroomGalleryClient
    private let fileLog: FileLog
    private let bridge: EventBridge
    private var ledger: Ledger?
    private var engine: SyncEngine?
    private let aboutWindow = AboutWindow()
    private var loopTask: Task<Void, Never>?
    private var spinnerTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var lastAttemptAt: Date?

    init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let support = library.appendingPathComponent("Application Support/LightroomSync", isDirectory: true)
        logFileURL = library.appendingPathComponent("Logs/LightroomSync/sync.log")

        let store = UserDefaultsSettingsStore(defaults: .standard)
        self.store = store
        editor = SyncSettingsEditor(saved: store.load())

        client = LightroomGalleryClient(transport: URLSessionTransport())
        fileLog = FileLog(fileURL: logFileURL)
        bridge = EventBridge(fileLog: fileLog)
        bridge.model = self

        do {
            let ledger = try Ledger(fileURL: support.appendingPathComponent("ledger.json"))
            self.ledger = ledger
            let photoKit = PhotoKitImporter()
            engine = SyncEngine(client: client, ledger: ledger, importer: photoKit, photoLibrary: photoKit,
                                resizer: ImageResizer(), metadataWriter: ImageMetadataWriter(),
                                downloadDirectory: support.appendingPathComponent("downloads", isDirectory: true),
                                sink: bridge)
            syncedCount = ledger.syncedCount
        } catch {
            setupError = "Could not open the sync ledger: \(error.localizedDescription)"
            fileLog.append("[error] \(setupError ?? "")")
        }

        launchAtLogin = LoginItem.isEnabled
        fileLog.append("Lightroom Sync started")
        validateSavedLink()
        startLoop()
    }

    // MARK: Derived state for the UI

    var isSyncing: Bool {
        if case .syncing = phase { return true }
        return false
    }

    var hasUnsavedChanges: Bool { editor.hasUnsavedChanges }

    var hasSavedSettings: Bool { editor.saved?.isConfigured == true }

    var canSave: Bool { hasUnsavedChanges }

    /// "Sync now" runs the saved settings, so it waits for unsaved edits to be saved or reverted.
    var canSync: Bool { engine != nil && !isSyncing && editor.isReadyToSync }

    var syncNowHelp: String {
        if hasUnsavedChanges { return "Save the settings first. Checks always run on the saved settings." }
        if !hasSavedSettings { return "Enter the album's share link and press Save." }
        return "Check the album now and sync new photos without waiting for the delay."
    }

    /// The menu bar item's image. While a pass runs this is one frame of the turning sync symbol,
    /// advanced by `spinnerTask`.
    var menuBarImage: NSImage {
        switch statusKind {
        case .syncing: return MenuBarIcon.spinner(frame: spinnerFrame)
        case .failed: return MenuBarIcon.symbol(MenuBarIcon.failedSymbol)
        default: return MenuBarIcon.symbol(MenuBarIcon.idleSymbol)
        }
    }

    var statusKind: StatusKind {
        if setupError != nil { return .failed }
        switch phase {
        case .syncing: return .syncing
        case .failed: return .failed
        case .idle:
            if !hasSavedSettings { return .unconfigured }
            if hasUnsavedChanges { return .unsaved }
            if let report = lastReport, report.failed > 0 { return .failed }
            return .ok
        }
    }

    var statusLine: String {
        if let setupError { return setupError }
        switch phase {
        case .syncing(let completed, let total):
            return total > 0 ? "Syncing \(completed) of \(total)…" : "Checking the album…"
        case .failed(let message):
            return "Last check failed: \(message)"
        case .idle:
            guard hasSavedSettings else { return "Not set up yet. Paste the share link and press Save." }
            guard let lastSyncAt else { return "Waiting for the first check" }
            var line = "Last check \(Self.timeFormatter.string(from: lastSyncAt))"
            if let report = lastReport {
                var details = ["\(report.synced) new"]
                if report.pending > 0 { details.append("\(report.pending) waiting") }
                if report.foundInPhotos > 0 { details.append("\(report.foundInPhotos) already in Photos") }
                if report.refiled > 0 { details.append("\(report.refiled) put back in the album") }
                if report.failed > 0 { details.append("\(report.failed) failed") }
                line += " · " + details.joined(separator: ", ")
            }
            return line
        }
    }

    /// The running total, shown under the status line once anything has been synced.
    var totalSyncedLine: String? {
        guard syncedCount > 0 else { return nil }
        return syncedCount == 1 ? "1 photo synced in total" : "\(syncedCount) photos synced in total"
    }

    var saveStateText: String {
        if hasUnsavedChanges { return "Unsaved changes" }
        return hasSavedSettings ? "Settings saved" : "Not saved yet"
    }

    /// Albums to choose between, once the saved link has been read.
    var availableAlbums: [AlbumInfo] { shareInfo?.albums ?? [] }

    // MARK: Actions

    func save() {
        guard canSave else { return }
        let settings = editor.save()
        store.save(settings)
        // Check promptly with the new settings rather than waiting out the old interval.
        lastAttemptAt = nil
        phase = .idle
        let description = settings.isConfigured ? "saved" : "cleared"
        bridge.log(.info, "Settings \(description): every \(settings.intervalDescription)"
            + ", photos at \(settings.photoSize.shortDescription)"
            + (settings.photosAlbumName.isEmpty ? ", no Photos album" : ", Photos album “\(settings.photosAlbumName)”"))
        validateSavedLink()
    }

    func setIntervalUnit(_ unit: IntervalUnit) {
        editor.setIntervalUnit(unit)
    }

    func revert() {
        editor.revert()
        validateSavedLink()
    }

    func syncNow() {
        guard canSync else { return }
        Task { await runSync(ignoreDelays: true) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            launchAtLogin = LoginItem.isEnabled
        } catch {
            bridge.log(.error, "Could not change login item: \(error.localizedDescription)")
            launchAtLogin = LoginItem.isEnabled
        }
    }

    func showAbout() {
        aboutWindow.show()
    }

    func openLog() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            fileLog.append("Log created")
        }
        NSWorkspace.shared.open(logFileURL)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Internal updates (called through EventBridge)

    func updateProgress(completed: Int, total: Int) {
        if case .syncing = phase {
            phase = .syncing(completed: completed, total: total)
        }
    }

    // MARK: Reading the saved share link

    /// Reads the saved link, never the draft: typing in the panel contacts nothing.
    private func validateSavedLink() {
        validationTask?.cancel()
        guard let settings = editor.saved, settings.isConfigured else {
            shareInfo = nil
            shareStatus = "Paste the album's share link from Lightroom (Share & Invite › Link), then press Save."
            linkStatus = .unknown
            return
        }
        shareStatus = "Reading the album…"
        linkStatus = .checking
        validationTask = Task { [weak self] in
            await self?.readShare(settings)
        }
    }

    private func readShare(_ settings: SyncSettings) async {
        do {
            let link = try AlbumShareLink.parse(settings.shareLink)
            let (shareID, linkAlbumID) = try await client.resolve(link)
            let info = try await client.fetchShare(shareID: shareID)
            guard !Task.isCancelled, editor.saved?.shareLink == settings.shareLink else { return }
            shareInfo = info

            // Never write to the draft from here: that would show as an unsaved change the user
            // never made, and hold back the next check. With no album chosen, the engine syncs the
            // album the link points at, or the first one.
            let effectiveAlbumID = settings.albumID ?? linkAlbumID
            let albumName = info.albums.first(where: { $0.id == effectiveAlbumID })?.name
                ?? info.albums.first?.name

            if info.albums.isEmpty {
                shareStatus = "This share contains no albums."
                linkStatus = .problem
            } else if !info.downloadsAllowed {
                shareStatus = "Downloads are off for “\(albumName ?? "?")”. Turn on “Allow downloads” in Lightroom's share settings."
                linkStatus = .problem
            } else {
                shareStatus = "“\(albumName ?? "?")” · downloads allowed"
                linkStatus = .ok
            }
        } catch {
            guard !Task.isCancelled else { return }
            shareInfo = nil
            shareStatus = error.localizedDescription
            linkStatus = .problem
        }
    }

    // MARK: Scheduling

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func tick() async {
        guard !isSyncing, engine != nil, editor.isReadyToSync, let settings = editor.saved else { return }
        let schedule = SyncSchedule(interval: settings.checkInterval)
        guard schedule.shouldStart(now: Date(), lastAttempt: lastAttemptAt) else { return }
        await runSync(ignoreDelays: false)
    }

    /// Turns the menu bar symbol while a pass runs. Twelve frames at 80 ms is one turn a second.
    private func startSpinner() {
        guard spinnerTask == nil else { return }
        spinnerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self else { return }
                self.spinnerFrame = (self.spinnerFrame + 1) % MenuBarIcon.spinnerFrameCount
            }
        }
    }

    private func stopSpinner() {
        spinnerTask?.cancel()
        spinnerTask = nil
        spinnerFrame = 0
    }

    private func runSync(ignoreDelays: Bool) async {
        guard let engine, let settings = editor.saved, settings.isConfigured, !isSyncing else { return }
        lastAttemptAt = Date()
        phase = .syncing(completed: 0, total: 0)
        startSpinner()
        defer { stopSpinner() }
        do {
            let report = try await engine.run(settings.syncConfiguration(ignoreDelays: ignoreDelays))
            lastReport = report
            lastSyncAt = Date()
            syncedCount = ledger?.syncedCount ?? syncedCount
            phase = .idle
            var summary = "Check finished in \(Stopwatch.describe(report.duration)): \(report.synced) synced, \(report.pending) waiting, \(report.failed) failed"
            if report.foundInPhotos > 0 { summary += ", \(report.foundInPhotos) already in Photos" }
            if report.refiled > 0 { summary += ", \(report.refiled) put back into “\(settings.photosAlbumName)”" }
            bridge.log(.info, summary)
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
            bridge.log(.error, error.localizedDescription)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
#endif
