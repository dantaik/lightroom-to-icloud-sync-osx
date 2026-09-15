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

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case syncing(completed: Int, total: Int)
        case failed(String)
    }

    private enum Keys {
        static let shareLink = "shareLink"
        static let albumID = "selectedAlbumID"
        static let photosAlbum = "photosAlbumName"
        static let interval = "intervalMinutes"
    }

    // MARK: Settings (persisted in UserDefaults)

    @Published var shareLink: String {
        didSet {
            guard shareLink != oldValue else { return }
            defaults.set(shareLink, forKey: Keys.shareLink)
            settingsChanged()
            scheduleShareValidation()
        }
    }

    @Published var selectedAlbumID: String? {
        didSet {
            guard selectedAlbumID != oldValue else { return }
            defaults.set(selectedAlbumID, forKey: Keys.albumID)
            settingsChanged()
        }
    }

    @Published var photosAlbumName: String {
        didSet {
            guard photosAlbumName != oldValue else { return }
            defaults.set(photosAlbumName, forKey: Keys.photosAlbum)
            settingsChanged()
        }
    }

    @Published var intervalMinutes: Int {
        didSet {
            guard intervalMinutes != oldValue else { return }
            defaults.set(intervalMinutes, forKey: Keys.interval)
            settingsChanged()
        }
    }

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

    private let defaults = UserDefaults.standard
    private let client: LightroomGalleryClient
    private let fileLog: FileLog
    private let bridge: EventBridge
    private var ledger: Ledger?
    private var engine: SyncEngine?
    private var loopTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private var lastSettingsChangeAt: Date?

    init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let support = library.appendingPathComponent("Application Support/LightroomSync", isDirectory: true)
        logFileURL = library.appendingPathComponent("Logs/LightroomSync/sync.log")

        shareLink = defaults.string(forKey: Keys.shareLink) ?? ""
        selectedAlbumID = defaults.string(forKey: Keys.albumID)
        photosAlbumName = defaults.string(forKey: Keys.photosAlbum) ?? ""
        let storedInterval = defaults.integer(forKey: Keys.interval)
        intervalMinutes = storedInterval > 0 ? min(storedInterval, 1440) : 15

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
        scheduleShareValidation(delay: 0)
        startLoop()
    }

    // MARK: Derived state for the UI

    var isSyncing: Bool {
        if case .syncing = phase { return true }
        return false
    }

    var canSync: Bool {
        engine != nil && !isSyncing && !shareLink.trimmingCharacters(in: .whitespaces).isEmpty
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

    // MARK: Actions

    func syncNow() {
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

    // MARK: Share link validation

    private func scheduleShareValidation(delay: TimeInterval = 0.8) {
        validationTask?.cancel()
        let link = shareLink
        validationTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            await self.validate(link: link)
        }
    }

    private func validate(link: String) async {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            shareInfo = nil
            shareStatus = "Paste the album's share link from Lightroom (Share & Invite › Link)."
            shareStatusIsError = false
            return
        }
        let parsed: AlbumShareLink
        do {
            parsed = try AlbumShareLink.parse(trimmed)
        } catch {
            shareInfo = nil
            shareStatus = error.localizedDescription
            shareStatusIsError = true
            return
        }
        shareStatus = "Checking link…"
        shareStatusIsError = false
        do {
            let (shareID, linkAlbumID) = try await client.resolve(parsed)
            let info = try await client.fetchShare(shareID: shareID)
            guard !Task.isCancelled, shareLink.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            shareInfo = info
            if let selected = selectedAlbumID, info.albums.contains(where: { $0.id == selected }) {
                // keep the user's choice
            } else {
                selectedAlbumID = linkAlbumID ?? info.albums.first?.id
            }
            let albumName = info.albums.first(where: { $0.id == selectedAlbumID })?.name
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

    /// Records that a setting was just edited. The panel writes every keystroke straight through,
    /// so an automatic pass must not start until the typing has stopped.
    private func settingsChanged() {
        lastSettingsChangeAt = Date()
    }

    private func tick() async {
        guard !isSyncing, engine != nil else { return }
        guard !shareLink.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let schedule = SyncSchedule(interval: TimeInterval(intervalMinutes * 60))
        guard schedule.shouldStart(now: Date(), lastAttempt: lastAttemptAt, lastSettingsChange: lastSettingsChangeAt) else {
            return
        }
        await runSync(ignoreDelays: false)
    }

    private func runSync(ignoreDelays: Bool) async {
        guard let engine, !isSyncing else { return }
        lastAttemptAt = Date()
        phase = .syncing(completed: 0, total: 0)
        let trimmedAlbum = photosAlbumName.trimmingCharacters(in: .whitespaces)
        let config = SyncConfiguration(shareLink: shareLink,
                                       preferredAlbumID: selectedAlbumID,
                                       photosAlbumName: trimmedAlbum.isEmpty ? nil : trimmedAlbum,
                                       checkInterval: TimeInterval(intervalMinutes * 60),
                                       ignoreDelays: ignoreDelays)
        do {
            let report = try await engine.run(config)
            lastReport = report
            lastSyncAt = Date()
            syncedCount = ledger?.syncedCount ?? syncedCount
            phase = .idle
            var summary = "Check finished: \(report.synced) synced, \(report.pending) waiting, \(report.failed) failed"
            if report.foundInPhotos > 0 { summary += ", \(report.foundInPhotos) already in Photos" }
            if report.refiled > 0 { summary += ", \(report.refiled) put back into “\(trimmedAlbum)”" }
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
