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
        let line = level == .info ? message : "[\(level.rawValue)] \(message)"
        fileLog.append(line)
        let model = self.model
        Task { @MainActor in model?.appendActivity(line) }
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
        static let interval = "intervalMinutes"
    }

    let defaults: UserDefaults

    func load() -> SyncSettings? {
        // No share link key at all means the user has never saved anything.
        guard let shareLink = defaults.string(forKey: Keys.shareLink) else { return nil }
        let interval = defaults.integer(forKey: Keys.interval)
        return SyncSettings(
            shareLink: shareLink,
            albumID: defaults.string(forKey: Keys.albumID),
            photosAlbumName: defaults.string(forKey: Keys.photosAlbum) ?? "",
            intervalMinutes: interval > 0 ? interval : SyncSettings.defaultIntervalMinutes
        ).normalized
    }

    func save(_ settings: SyncSettings) {
        defaults.set(settings.shareLink, forKey: Keys.shareLink)
        defaults.set(settings.albumID, forKey: Keys.albumID)
        defaults.set(settings.photosAlbumName, forKey: Keys.photosAlbum)
        defaults.set(settings.intervalMinutes, forKey: Keys.interval)
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case syncing(completed: Int, total: Int)
        case failed(String)
    }

    /// The settings being edited. Only `editor.saved` drives syncing.
    @Published var editor: SyncSettingsEditor
    @Published private(set) var launchAtLogin = false

    // MARK: Runtime state

    @Published private(set) var shareInfo: ShareInfo?
    @Published private(set) var shareStatus = ""
    @Published private(set) var shareStatusIsError = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastReport: SyncReport?
    @Published private(set) var syncedCount = 0
    @Published private(set) var activity: [String] = []
    @Published private(set) var setupError: String?

    let logFileURL: URL

    private let store: SyncSettingsStore
    private let client: LightroomGalleryClient
    private let fileLog: FileLog
    private let bridge: EventBridge
    private var ledger: Ledger?
    private var engine: SyncEngine?
    private var loopTask: Task<Void, Never>?
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

    var menuSymbol: String {
        switch phase {
        case .idle: return "photo.on.rectangle.angled"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var statusLine: String {
        if let setupError { return setupError }
        switch phase {
        case .syncing(let completed, let total):
            return total > 0 ? "Syncing \(completed) of \(total)…" : "Checking album…"
        case .failed(let message):
            return "Last check failed: \(message)"
        case .idle:
            guard hasSavedSettings else { return "Not set up yet. Paste the share link and press Save." }
            var parts: [String] = []
            if let lastSyncAt {
                parts.append("Last check \(Self.timeFormatter.string(from: lastSyncAt))")
            } else {
                parts.append("No check yet")
            }
            if let report = lastReport, report.pending > 0 {
                parts.append("\(report.pending) waiting")
            }
            parts.append("\(syncedCount) synced in total")
            return parts.joined(separator: " · ")
        }
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
        bridge.log(.info, "Settings \(description): every \(settings.intervalMinutes) min"
            + (settings.photosAlbumName.isEmpty ? ", no Photos album" : ", Photos album “\(settings.photosAlbumName)”"))
        validateSavedLink()
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
            appendActivity("[error] Could not change login item: \(error.localizedDescription)")
            launchAtLogin = LoginItem.isEnabled
        }
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

    func appendActivity(_ line: String) {
        activity.append(line)
        if activity.count > 6 { activity.removeFirst(activity.count - 6) }
    }

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
            shareStatusIsError = false
            return
        }
        shareStatus = "Reading the album…"
        shareStatusIsError = false
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
                shareStatusIsError = true
            } else if !info.downloadsAllowed {
                shareStatus = "Album “\(albumName ?? "?")” found, but downloads are off. Turn on “Allow downloads” in Lightroom's share settings."
                shareStatusIsError = true
            } else {
                shareStatus = "Album “\(albumName ?? "?")” · downloads allowed"
                shareStatusIsError = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            shareInfo = nil
            shareStatus = error.localizedDescription
            shareStatusIsError = true
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

    private func runSync(ignoreDelays: Bool) async {
        guard let engine, let settings = editor.saved, settings.isConfigured, !isSyncing else { return }
        lastAttemptAt = Date()
        phase = .syncing(completed: 0, total: 0)
        do {
            let report = try await engine.run(settings.syncConfiguration(ignoreDelays: ignoreDelays))
            lastReport = report
            lastSyncAt = Date()
            syncedCount = ledger?.syncedCount ?? syncedCount
            phase = .idle
            var summary = "Check finished: \(report.synced) synced, \(report.pending) waiting, \(report.failed) failed"
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
