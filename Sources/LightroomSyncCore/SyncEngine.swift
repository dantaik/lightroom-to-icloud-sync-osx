import Foundation

public struct SyncConfiguration: Equatable {
    public var shareLink: String
    public var preferredAlbumID: String?
    public var photosAlbumName: String?
    public var checkInterval: TimeInterval
    /// How large the synced photos should be.
    public var photoSize: PhotoSize
    public var ignoreDelays: Bool
    /// How many photos are fetched at once. Clamped to ``SyncSettings/downloadConcurrencyRange``.
    public var downloadConcurrency: Int

    public init(shareLink: String, preferredAlbumID: String? = nil, photosAlbumName: String? = nil,
                checkInterval: TimeInterval, photoSize: PhotoSize = .default, ignoreDelays: Bool = false,
                downloadConcurrency: Int = SyncSettings.defaultDownloadConcurrency) {
        self.shareLink = shareLink
        self.preferredAlbumID = preferredAlbumID
        self.photosAlbumName = photosAlbumName
        self.checkInterval = checkInterval
        self.photoSize = photoSize
        self.ignoreDelays = ignoreDelays
        self.downloadConcurrency = downloadConcurrency
    }
}

public struct SyncReport: Equatable {
    public var shareID: String
    public var albumID: String
    public var albumName: String
    public var photosInAlbum = 0
    public var synced = 0
    public var pending = 0
    public var alreadySynced = 0
    public var duplicates = 0
    /// Photos that Photos already held, so they were recorded without downloading.
    public var foundInPhotos = 0
    /// Already-synced photos that were put back into the configured album.
    public var refiled = 0
    public var failed = 0
    public var downgraded = 0
    /// Photos that arrived without the metadata a camera writes, and had Lightroom's copy of it
    /// put back in before they were imported.
    public var metadataRestored = 0
    public var startedAt: Date
    public var finishedAt: Date
    /// How long the pass took, on a monotonic clock. `finishedAt - startedAt` will not do:
    /// `startedAt` is the timestamp the pass reasons against, which a caller may set to anything.
    public var duration: Duration = .zero
    /// Where that time went, so a slow pass says which step was slow.
    public var timings = SyncTimings()

    public init(shareID: String, albumID: String, albumName: String, startedAt: Date) {
        self.shareID = shareID
        self.albumID = albumID
        self.albumName = albumName
        self.startedAt = startedAt
        self.finishedAt = startedAt
    }
}

public enum LogLevel: String {
    case info, warning, error
}

/// What a pass is doing before it has photos to count.
///
/// Every one of these is a wait with no number behind it — a redirect to follow, an album that
/// pages, a Photos library that has to be opened and, on the first pass after the app starts,
/// asked for permission. Until they are done the pass does not know how many photos it is going
/// to sync, so all it can report is which one of them is running.
///
/// The raw values order the stages, which is the order `run` reports them in.
public enum SyncStage: Int, Comparable, CustomStringConvertible, Sendable {
    /// Following the share link to the share it names.
    case resolvingLink = 0
    /// Reading the share: its albums, and whether it allows downloads at all.
    case readingShare = 1
    /// Paging through the album's photos.
    case listingAlbum = 2
    /// Making sure the Photos album still holds what was already synced into it.
    case refilingAlbum = 3
    /// Clearing out whatever an interrupted pass left in the download directory.
    case clearingDownloads = 4

    /// What the panel says while this stage runs.
    public var description: String {
        switch self {
        case .resolvingLink: return "Opening the share link…"
        case .readingShare: return "Reading the share…"
        case .listingAlbum: return "Listing the album…"
        case .refilingAlbum: return "Checking the Photos album…"
        case .clearingDownloads: return "Clearing unfinished downloads…"
        }
    }

    public static func < (lhs: SyncStage, rhs: SyncStage) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Receives progress and log lines from a sync pass. Called from arbitrary threads.
public protocol SyncEventSink: AnyObject {
    func log(_ level: LogLevel, _ message: String)
    func progress(completed: Int, total: Int)
    /// Which step of the run-up to the photos the pass is on. See ``SyncStage``.
    func stage(_ stage: SyncStage)
}

public extension SyncEventSink {
    /// A sink that only cares about the photos themselves need not follow the run-up to them.
    func stage(_ stage: SyncStage) {}
}

public enum SyncEngineError: Error, LocalizedError, Equatable {
    case invalidShareLink(String)
    case noAlbums
    case albumNotFound(String)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .invalidShareLink(let detail): return detail
        case .noAlbums: return "This share contains no albums."
        case .albumNotFound(let id): return "The selected album (\(id)) is no longer part of this share."
        case .alreadyRunning: return "A check is already running."
        }
    }
}

/// Runs one sync pass: list the shared album, download eligible photos, import them, record them.
public final class SyncEngine {
    private let client: LightroomGalleryClient
    private let ledger: Ledger
    private let importer: PhotoImporting
    private let photoLibrary: PhotoLibraryAccess
    private let resizer: PhotoResizing
    private let metadataWriter: PhotoMetadataWriting
    private let localSource: LocalPhotoSource
    private let downloadDirectory: URL
    private let settleTime: TimeInterval
    private weak var sink: SyncEventSink?

    /// Guards against a second pass starting on top of one already running.
    ///
    /// Two passes share this engine's ledger and its download directory, and starting up sweeps
    /// that directory — which, with a pass already running, is its downloads, mid-flight. The app
    /// has its own guard on top of this one; this is the one the ledger actually depends on.
    private let runLock = NSLock()
    private var isRunning = false

    /// How far a Photos asset's creation date may differ from Lightroom's capture date and still
    /// be the same photo. Lightroom reports capture times without a zone, so two Macs in different
    /// time zones read the same photo as up to a day apart.
    public static let captureDateTolerance: TimeInterval = 26 * 3600

    public init(client: LightroomGalleryClient, ledger: Ledger, importer: PhotoImporting,
                photoLibrary: PhotoLibraryAccess = NullPhotoLibraryAccess(),
                resizer: PhotoResizing = NoPhotoResizing(),
                metadataWriter: PhotoMetadataWriting = NoPhotoMetadataWriting(),
                localSource: LocalPhotoSource = NoLocalPhotoSource(),
                downloadDirectory: URL, settleTime: TimeInterval = SyncPolicy.defaultSettleTime,
                sink: SyncEventSink?) {
        self.client = client
        self.ledger = ledger
        self.importer = importer
        self.photoLibrary = photoLibrary
        self.resizer = resizer
        self.metadataWriter = metadataWriter
        self.localSource = localSource
        self.downloadDirectory = downloadDirectory
        self.settleTime = settleTime
        self.sink = sink
    }

    public func run(_ config: SyncConfiguration, now: Date = Date()) async throws -> SyncReport {
        guard beginRun() else { throw SyncEngineError.alreadyRunning }
        defer { endRun() }
        let pass = Stopwatch()
        let link: AlbumShareLink
        do {
            link = try AlbumShareLink.parse(config.shareLink)
        } catch {
            throw SyncEngineError.invalidShareLink(error.localizedDescription)
        }
        sink?.stage(.resolvingLink)
        let (shareID, linkAlbumID) = try await client.resolve(link)
        sink?.stage(.readingShare)
        let share = try await client.fetchShare(shareID: shareID)
        let album = try Self.chooseAlbum(from: share, preferred: config.preferredAlbumID ?? linkAlbumID)
        var report = SyncReport(shareID: shareID, albumID: album.id, albumName: album.name, startedAt: now)

        guard share.downloadsAllowed else { throw LightroomError.downloadsDisabled }

        sink?.stage(.listingAlbum)
        let photos = try await client.listPhotos(shareID: shareID, albumID: album.id).filter(\.isImage)
        report.timings.listing = pass.elapsed
        report.photosInAlbum = photos.count
        let candidates = photos.filter { !ledger.contains(assetID: $0.assetID) }
        report.alreadySynced = photos.count - candidates.count
        let policy = SyncPolicy(minimumAgeInAlbum: SyncPolicy.minimumAge(forCheckInterval: config.checkInterval),
                                settleTime: settleTime, ignoreDelays: config.ignoreDelays)
        let albumName = config.photosAlbumName.flatMap { $0.isEmpty ? nil : $0 }
        log(.info, "Album “\(album.name)”: \(photos.count) photos, \(candidates.count) not yet synced, at \(config.photoSize.shortDescription) (listed in \(Stopwatch.describe(report.timings.listing)))")

        let refiling = Stopwatch()
        // Only with an album to keep in step: without one `refileIntoAlbum` returns at once, and
        // announcing a step that is not going to run would be a lie the panel then has to show.
        if albumName != nil { sink?.stage(.refilingAlbum) }
        await refileIntoAlbum(albumName, photos: photos, report: &report)
        report.timings.refiling = refiling.elapsed

        // Whatever a previous pass left behind when it was stopped mid-fetch. The directory is
        // this engine's alone and only one pass uses it at a time, so anything already in it is a
        // leftover. Several photos are now in flight at once, so a stop strands several files.
        sink?.stage(.clearingDownloads)
        sweepDownloadDirectory()
        // The last of the run-up: from here the pass has a number, and progress is a count rather
        // than the name of a step.
        sink?.progress(completed: 0, total: candidates.count)

        let width = max(1, SyncSettings.clamp(downloadConcurrency: config.downloadConcurrency))
        var completed = 0
        /// Counts one candidate as dealt with, whatever became of it.
        func advance() {
            completed += 1
            sink?.progress(completed: completed, total: candidates.count)
        }

        // Three stages. What touches the ledger, the report or Photos runs here on one task and
        // stays in order; only the fetch — the download, which is Lightroom rendering on demand,
        // plus the resizing and metadata that follow it — is run several at a time. Widening the
        // other two would buy nothing (Photos serializes its own changes) and would race: the
        // ledger is a plain dictionary behind a whole-file write, and the duplicate checks read
        // it before acting on it.
        try await withThrowingTaskGroup(of: FetchOutcome.self) { group in
            var next = 0
            var inFlight = 0
            /// The identities being fetched right now, so that the same photograph is never
            /// fetched twice. See ``identityKeys(of:)``.
            var beingFetched: Set<String> = []

            while true {
                while inFlight < width, next < candidates.count {
                    try Task.checkCancellation()
                    let photo = candidates[next]
                    // A photo that shares an identity with one already being fetched has to wait
                    // for it. Both duplicate checks are answered by a ledger entry that is not
                    // written until that fetch has been imported and recorded, and so is the
                    // Photos lookup, which cannot find a photo that is still downloading — so
                    // dispatching this one now would import the same photograph twice. Left in
                    // place, not consumed: it is settled again once the one ahead of it has landed.
                    let identities = Self.identityKeys(of: photo)
                    if identities.contains(where: beingFetched.contains) { break }
                    next += 1
                    let settlement = try await settle(photo, shareID: shareID, albumID: album.id,
                                                      albumName: albumName, policy: policy, now: now)
                    switch settlement {
                    case .fetch(let name, let timings):
                        beingFetched.formUnion(identities)
                        group.addTask { [self] in
                            await fetch(photo, name: name, shareID: shareID, config: config, timings: timings)
                        }
                        inFlight += 1
                    case .settled(let outcome, let timings):
                        switch outcome {
                        case .duplicate: report.duplicates += 1
                        case .waiting: report.pending += 1
                        case .foundInPhotos: report.foundInPhotos += 1
                        }
                        report.timings.add(timings)
                        advance()
                    }
                }
                // `beingFetched` is only ever non-empty while something is in flight, so a photo
                // held back above always has a fetch left to drain and cannot deadlock here.
                guard inFlight > 0, let outcome = try await group.next() else { break }
                inFlight -= 1
                // Safe to subtract wholesale: a photo sharing any of these keys was held back
                // above, so no two photos in flight ever carry the same one.
                beingFetched.subtract(Self.identityKeys(of: outcome.photo))
                await finish(outcome, shareID: shareID, albumID: album.id, albumName: albumName,
                             now: now, report: &report)
                advance()
            }
        }

        report.finishedAt = Date()
        report.duration = pass.elapsed
        log(.info, "Pass took \(Stopwatch.describe(report.duration)): \(report.timings.summary)")
        // A pass that was slow says what it was slow because of, rather than leaving the numbers
        // above to be ranked by hand.
        if let diagnosis = report.timings.diagnosis { log(.info, diagnosis) }
        return report
    }

    /// Claims the engine for one pass, or reports that another already holds it.
    private func beginRun() -> Bool {
        runLock.withLock {
            guard !isRunning else { return false }
            isRunning = true
            return true
        }
    }

    private func endRun() {
        runLock.withLock { isRunning = false }
    }

    // MARK: - The three stages

    /// What the serial stage decided about a photo, before anything is fetched.
    private enum Settlement {
        enum Outcome { case duplicate, waiting, foundInPhotos }
        /// Nothing more to do: a duplicate, not eligible yet, or Photos already had it.
        case settled(Outcome, PhotoTimings)
        /// It has to be fetched from Lightroom.
        case fetch(name: String, timings: PhotoTimings)
    }

    /// What the concurrent fetch stage produced. It carries a file on disk, so every path out of
    /// the fetch either hands that file on to be imported or has already deleted it.
    private enum FetchOutcome {
        case fetched(FetchedPhoto)
        case failed(photo: LightroomPhoto, name: String, message: String, timings: PhotoTimings)

        var photo: LightroomPhoto {
            switch self {
            case .fetched(let fetched): return fetched.photo
            case .failed(let photo, _, _, _): return photo
            }
        }
    }

    /// A photo downloaded, resized and described, waiting its turn to be imported.
    private struct FetchedPhoto {
        let photo: LightroomPhoto
        let name: String
        let fileURL: URL
        let fileName: String?
        /// The picture's own hash, taken on the download before it was resized or described.
        let contentSHA256: String?
        let metadata: PhotoMetadata
        let size: JPEGInfo.PixelSize?
        let downgraded: Bool
        let metadataRestored: Bool
        var timings: PhotoTimings
    }

    /// Stage one, serial: everything that reads or writes the ledger, and the Photos lookup.
    ///
    /// The waiting rules come before the Photos lookup because they are free and it is not: it
    /// scans every asset in the library within a day of the capture date, and a photo that is not
    /// eligible yet would pay for that on every pass until it was.
    private func settle(_ photo: LightroomPhoto, shareID: String, albumID: String, albumName: String?,
                        policy: SyncPolicy, now: Date) async throws -> Settlement {
        let name = photo.fileName ?? photo.assetID
        var timings = PhotoTimings()

        if let match = syncedDuplicate(of: photo) {
            var duplicate = match.entry
            duplicate.assetID = photo.assetID
            duplicate.shareID = shareID
            duplicate.albumID = albumID
            duplicate.syncedAt = now
            let recording = Stopwatch()
            try ledger.record(duplicate)
            timings.ledger += recording.elapsed
            log(.info, "Skipping \(name): \(match.reason)")
            return .settled(.duplicate, timings)
        }

        let noting = Stopwatch()
        let firstSeen = try ledger.noteSeen(assetID: photo.assetID, at: now)
        timings.ledger += noting.elapsed
        if case .wait(let reason) = policy.decision(for: photo, firstSeen: firstSeen, now: now) {
            log(.info, "Waiting on \(name): \(reason)")
            return .settled(.waiting, timings)
        }

        let searching = Stopwatch()
        let lookup = await findInPhotos(photo, albumName: albumName)
        if lookup.queried {
            timings.lookup = searching.elapsed
            timings.didLookup = true
        }
        if let identifier = lookup.identifier {
            let recording = Stopwatch()
            try ledger.record(LedgerEntry(assetID: photo.assetID, shareID: shareID, albumID: albumID,
                                          fileName: photo.expectedPhotosFileName ?? photo.fileName,
                                          originalSHA256: photo.originalSHA256,
                                          photosLocalIdentifier: identifier, photosAlbumName: albumName,
                                          syncedAt: now, captureDate: photo.captureDate,
                                          pixelWidth: nil, pixelHeight: nil, downgraded: false))
            timings.ledger += recording.elapsed
            log(.info, "\(name) is already in Photos; recorded it without downloading (lookup \(Stopwatch.describe(timings.lookup)))")
            return .settled(.foundInPhotos, timings)
        }

        return .fetch(name: name, timings: timings)
    }

    /// An already-synced photo that is this same photograph, and why it counts as one.
    ///
    /// Two things can say so, and both are free — they only read the ledger. The original's hash
    /// is the exact one, when Lightroom reports it for both copies. The file name and capture time
    /// are what is left when it does not: the same camera file name within a day of the same
    /// capture time is the same photograph, which is the very match the Photos lookup makes
    /// against the library. Making it here as well is what catches a copy whose twin was synced by
    /// an earlier pass, and what still holds when Photos cannot be asked.
    private func syncedDuplicate(of photo: LightroomPhoto) -> (entry: LedgerEntry, reason: String)? {
        if let sha = photo.originalSHA256, let existing = ledger.entry(withOriginalSHA256: sha) {
            return (existing, "the same original was already synced")
        }
        if let fileName = photo.expectedPhotosFileName, let captureDate = photo.captureDate,
           let existing = ledger.entry(withFileName: fileName, captureDate: captureDate,
                                       tolerance: Self.captureDateTolerance) {
            return (existing, "\(fileName) was already synced with the same capture time")
        }
        return nil
    }

    /// What makes two album entries the same photograph, as keys a set can hold: one per identity
    /// ``syncedDuplicate(of:)`` and the Photos lookup match on. A photo may have both or neither.
    ///
    /// The capture time is deliberately not part of the name key. Both of those checks match it
    /// within a day, which no exact key can express, so the name alone stands for it — the wider
    /// of the two nets, which is the right way round here: a photo held back is not a photo
    /// dropped, it is only settled again after the one ahead of it has landed.
    static func identityKeys(of photo: LightroomPhoto) -> [String] {
        var keys: [String] = []
        if let sha = photo.originalSHA256 { keys.append("sha:\(sha)") }
        if let fileName = photo.expectedPhotosFileName { keys.append("name:\(fileName.lowercased())") }
        return keys
    }

    /// Stage two, run several at a time: download the photo, bring it to the chosen size, and
    /// make sure the file says what Lightroom knows about it.
    ///
    /// Nothing here touches the ledger, the report or Photos, which is what makes running several
    /// of these at once safe. It never throws: a photo that cannot be fetched is one failure in
    /// the report, not the end of the pass, and cancellation has to leave the disk clean rather
    /// than unwind past the file it was writing.
    private func fetch(_ photo: LightroomPhoto, name: String, shareID: String,
                       config: SyncConfiguration, timings: PhotoTimings) async -> FetchOutcome {
        var timings = timings
        let downloaded: DownloadedPhoto
        let fetching = Stopwatch()
        do {
            downloaded = try await download(photo, shareID: shareID, size: config.photoSize, name: name)
            timings.download = fetching.elapsed
            timings.didDownload = true
        } catch {
            timings.download = fetching.elapsed
            timings.didDownload = true
            let message = error is CancellationError
                ? "the check was stopped" : error.localizedDescription
            return .failed(photo: photo, name: name, message: message, timings: timings)
        }

        if downloaded.throttleWait > .zero {
            log(.warning, "\(name): Lightroom asked for \(Stopwatch.describe(downloaded.throttleWait)) of waiting before it would serve this photo. Lower “Fetch at once” if this keeps happening.")
        }
        // Worth saying out loud even though it succeeded: a pass full of these is a network that
        // cannot hold a transfer open for as long as a full-size render takes, and the answer to
        // that is a smaller photo size or fewer at once, not more retries.
        if downloaded.transportRetries > 0 {
            let restart = downloaded.resumed ? "picked up where it stopped" : "started again"
            log(.warning, "\(name): the connection failed \(downloaded.transportRetries) time(s); the download was \(restart)"
                + " after \(Stopwatch.describe(downloaded.retryWait)) of waiting.")
        }

        // From here a file exists, so every way out has to account for it. Being cancelled with
        // the download already in hand is the common one: a stop should not leave 25 MB behind.
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: downloaded.fileURL)
            return .failed(photo: photo, name: name, message: "the check was stopped", timings: timings)
        }

        // The picture's own identity, taken here and nowhere else: on the file exactly as it was
        // served, before resizing changes its pixels and before its metadata is written back in.
        let hashing = Stopwatch()
        let contentSHA256 = PhotoContentHash.sha256(ofFileAt: downloaded.fileURL)
        timings.hashing = hashing.elapsed

        // What Lightroom served is measured against what the chosen size asks for, not against
        // the edited photo: a photo held back by the size setting is doing what it was told.
        let sizing = Stopwatch()
        let servedSize = JPEGInfo.pixelSize(ofFileAt: downloaded.fileURL)
        var downgraded = false
        if let servedSize,
           let intended = config.photoSize.intendedLongEdge(editedLongEdge: photo.expectedLongEdge),
           servedSize.longEdge + 2 < intended {
            downgraded = true
            log(.warning, "\(name): Lightroom served \(servedSize.width)×\(servedSize.height) but the edited photo is \(photo.croppedWidth ?? 0)×\(photo.croppedHeight ?? 0). Photos synced from Lightroom Classic only have smart previews in the cloud.")
        }

        let shrunk = shrink(downloaded.fileURL, servedSize: servedSize, to: config.photoSize, name: name)
        if shrunk != downloaded.fileURL { try? FileManager.default.removeItem(at: downloaded.fileURL) }
        let size = shrunk == downloaded.fileURL ? servedSize : (JPEGInfo.pixelSize(ofFileAt: shrunk) ?? servedSize)
        timings.resize = sizing.elapsed

        let describing = Stopwatch()
        let described = describe(shrunk, from: photo, name: name)
        timings.metadata = describing.elapsed

        // Lightroom serves a JPEG named after the original, and a rendition carries no name at
        // all, so the name it takes in Photos is the one the ledger and a second Mac look for.
        let fileName = downloaded.fileName ?? photo.expectedPhotosFileName ?? photo.fileName
        return .fetched(FetchedPhoto(photo: photo, name: name, fileURL: described.fileURL,
                                     fileName: fileName, contentSHA256: contentSHA256,
                                     metadata: described.metadata, size: size,
                                     downgraded: downgraded, metadataRestored: described.restored,
                                     timings: timings))
    }

    /// Stage three, serial: hand the file to Photos and write down what happened.
    ///
    /// Importing and recording sit next to each other on purpose. A photo that reaches Photos but
    /// is not recorded — the app quit in between — is found by the Photos lookup on the next pass
    /// and recorded then, without being downloaded or imported twice.
    private func finish(_ outcome: FetchOutcome, shareID: String, albumID: String, albumName: String?,
                        now: Date, report: inout SyncReport) async {
        switch outcome {
        case .failed(_, let name, let message, let timings):
            report.timings.add(timings)
            report.failed += 1
            log(.error, "Download failed for \(name) after \(Stopwatch.describe(timings.download)): \(message)")

        case .fetched(var fetched):
            // The last duplicate check, and the only one that can compare the pictures themselves.
            // It costs a download to reach, so it saves nothing before the fetch — what it saves
            // is the photo arriving in Photos a second time, which the ones before it can miss:
            // two copies Lightroom hashes differently, under two different file names, are
            // identical here. This runs on the one serial task, so the entry that answers it is
            // always the one written by the copy that went first.
            if let contentSHA256 = fetched.contentSHA256,
               let existing = ledger.entry(withContentSHA256: contentSHA256) {
                try? FileManager.default.removeItem(at: fetched.fileURL)
                let recording = Stopwatch()
                var duplicate = existing
                duplicate.assetID = fetched.photo.assetID
                duplicate.shareID = shareID
                duplicate.albumID = albumID
                duplicate.syncedAt = now
                do {
                    try ledger.record(duplicate)
                } catch {
                    log(.error, "\(fetched.name) is the same picture as one already synced, but could not be recorded in the ledger (\(error.localizedDescription))")
                }
                fetched.timings.ledger += recording.elapsed
                report.timings.add(fetched.timings)
                report.duplicates += 1
                log(.info, "Skipping \(fetched.name): the same picture was already synced as \(existing.fileName ?? existing.assetID)")
                return
            }

            if fetched.downgraded { report.downgraded += 1 }
            if fetched.metadataRestored {
                report.metadataRestored += 1
                log(.info, "\(fetched.name) arrived without its EXIF; Lightroom's copy of it was written back in")
            }
            let request = PhotoImportRequest(fileURL: fetched.fileURL,
                                             originalFileName: fetched.fileName,
                                             captureDate: fetched.metadata.captureDate ?? fetched.photo.captureDate,
                                             location: fetched.metadata.location,
                                             isFavorite: fetched.metadata.isFavorite,
                                             albumName: albumName)
            let localIdentifier: String
            let importing = Stopwatch()
            do {
                localIdentifier = try await importer.importPhoto(request)
                fetched.timings.importing = importing.elapsed
                fetched.timings.didImport = true
            } catch {
                fetched.timings.importing = importing.elapsed
                fetched.timings.didImport = true
                try? FileManager.default.removeItem(at: fetched.fileURL)
                report.timings.add(fetched.timings)
                report.failed += 1
                log(.error, "Import into Photos failed for \(fetched.name): \(error.localizedDescription)")
                return
            }
            try? FileManager.default.removeItem(at: fetched.fileURL)

            let recording = Stopwatch()
            do {
                try ledger.record(LedgerEntry(assetID: fetched.photo.assetID, shareID: shareID, albumID: albumID,
                                              fileName: fetched.fileName,
                                              originalSHA256: fetched.photo.originalSHA256,
                                              contentSHA256: fetched.contentSHA256,
                                              photosLocalIdentifier: localIdentifier, photosAlbumName: albumName,
                                              syncedAt: now, captureDate: request.captureDate,
                                              pixelWidth: fetched.size?.width, pixelHeight: fetched.size?.height,
                                              downgraded: fetched.downgraded))
            } catch {
                // The photo is in Photos either way. Saying so matters more than the pass ending
                // here: the next pass finds it in the library and records it then.
                log(.error, "\(fetched.name) was imported but could not be recorded in the ledger (\(error.localizedDescription)); the next check will pick it up from Photos")
            }
            fetched.timings.ledger += recording.elapsed
            report.timings.add(fetched.timings)
            report.synced += 1
            let dimensions = fetched.size.map { " (\($0.width)×\($0.height))" } ?? ""
            let breakdown = fetched.timings.breakdown
            log(.info, "Synced \(fetched.name)\(dimensions) in \(Stopwatch.describe(fetched.timings.total))"
                + (breakdown.isEmpty ? "" : " — \(breakdown)"))
        }
    }

    /// Clears out the download directory, which holds nothing worth keeping between passes: a
    /// file in it is either a download in progress or one a stopped pass abandoned.
    private func sweepDownloadDirectory() {
        let manager = FileManager.default
        guard let leftovers = try? manager.contentsOfDirectory(at: downloadDirectory,
                                                               includingPropertiesForKeys: nil)
        else { return }
        for file in leftovers { try? manager.removeItem(at: file) }
        if !leftovers.isEmpty {
            log(.info, "Cleared \(leftovers.count) unfinished download(s) left by an earlier check")
        }
    }

    /// Fetches a photo at the chosen size.
    ///
    /// When Lightroom already holds a rendition of that size, that is what is fetched: it is
    /// served as it stands, while the full-size file is rendered on demand and is many times
    /// larger. Any bigger size has to come from the download host and is shrunk afterwards.
    /// A rendition that cannot be fetched is not a failure; the full-size download still works.
    private func download(_ photo: LightroomPhoto, shareID: String, size: PhotoSize, name: String) async throws -> DownloadedPhoto {
        // Lightroom's own library on this Mac first: a file it has already rendered costs no
        // download at all, and the fastest photo is the one Adobe is never asked for.
        if let local = await localFile(for: photo, size: size, name: name) { return local }
        if let type = size.renditionType, let href = photo.renditionHref(forType: type) {
            do {
                return try await client.downloadRendition(shareID: shareID, assetID: photo.assetID,
                                                          href: href, to: downloadDirectory)
            } catch {
                log(.warning, "\(name): the \(type) px rendition could not be fetched (\(error.localizedDescription)); downloading the full-size photo instead")
            }
        }
        return try await client.downloadFullSize(shareID: shareID, assetID: photo.assetID, to: downloadDirectory)
    }

    /// Lightroom's copy of this photo on this Mac, when there is one fit to import.
    ///
    /// Three things have to hold before a local file is used, and a no to any of them means the
    /// photo is downloaded as usual — never an error, and never a silently worse photo:
    ///
    /// 1. A size was asked for. "Original" means every pixel Lightroom renders, and nothing on
    ///    disk can promise to be that.
    /// 2. The file is at least as large as the size asked for. A preview that falls short would
    ///    put a smaller photo into Photos than the settings call for, and the ledger would record
    ///    it as done at that size forever.
    /// 3. It was rendered after the last edit. Lightroom on this Mac can be behind the cloud —
    ///    an edit made on a phone reaches Adobe before it reaches here — and an older preview is
    ///    a picture of an older version of the photo.
    private func localFile(for photo: LightroomPhoto, size: PhotoSize, name: String) async -> DownloadedPhoto? {
        guard let wanted = size.maxLongEdge else { return nil }
        do {
            guard let file = try await localSource.localFile(for: photo, minimumLongEdge: wanted,
                                                            to: downloadDirectory) else { return nil }
            if let edited = photo.lastEditedAt, let rendered = file.renderedAt, rendered < edited {
                try? FileManager.default.removeItem(at: file.fileURL)
                log(.info, "\(name): Lightroom's copy on this Mac predates the last edit, so it was downloaded instead")
                return nil
            }
            log(.info, "\(name): taken from Lightroom's library on this Mac (\(file.source)) — nothing downloaded")
            return DownloadedPhoto(fileURL: file.fileURL, fileName: file.fileName,
                                   contentType: file.contentType, byteCount: file.byteCount)
        } catch {
            log(.warning, "\(name): could not read Lightroom's local copy (\(error.localizedDescription)); downloading it instead")
            return nil
        }
    }

    /// Brings a photo that came back larger than the chosen size down to it, and returns the file
    /// to import: the download itself when nothing had to change.
    ///
    /// Failing to resize is not failing to sync. The photo is imported as served, which is larger
    /// than asked for rather than missing, and the log says so.
    private func shrink(_ fileURL: URL, servedSize: JPEGInfo.PixelSize?, to size: PhotoSize, name: String) -> URL {
        guard let maxLongEdge = size.maxLongEdge, let servedSize, servedSize.longEdge > maxLongEdge else {
            return fileURL
        }
        do {
            return try resizer.resized(fileAt: fileURL, maxLongEdge: maxLongEdge)
        } catch {
            log(.warning, "Could not resize \(name) to \(maxLongEdge) px (\(error.localizedDescription)); importing it at \(servedSize.width)×\(servedSize.height)")
            return fileURL
        }
    }

    /// Settles what the photo says about itself, and makes sure the file says it too.
    ///
    /// Two things are decided here. The capture time, because Lightroom reports it without a zone
    /// and only the file knows which one the camera was set to. And whether the file is carrying
    /// Lightroom's description of the photo at all: the full-size download is, but the 2048 px
    /// rendition behind the Small size is a preview Adobe generated, and a photo that reaches
    /// Photos out of one has no camera, no keywords and no place on the map unless they are put
    /// back. Anything already in the file is left alone; only the gaps are filled.
    ///
    /// Returns the file to import, the metadata that was settled on, and whether the file had
    /// arrived stripped of it. Counting that is left to the caller: this runs on several photos
    /// at once and the report belongs to the one task that walks them in order. Failing to write
    /// metadata is not failing to sync: the photo is imported as served and the log says so.
    private func describe(_ fileURL: URL, from photo: LightroomPhoto,
                          name: String) -> (fileURL: URL, metadata: PhotoMetadata, restored: Bool) {
        let embedded = metadataWriter.embeddedMetadata(fileAt: fileURL)
        let captureTime = CaptureTime.resolve(rawCaptureDate: photo.rawCaptureDate,
                                              embeddedOffsetSeconds: embedded.captureTimeZoneOffset)
        var metadata = photo.metadata
        metadata.captureDate = captureTime.date ?? photo.captureDate
        metadata.captureTimeZoneOffset = captureTime.offsetSeconds

        // Nothing to say about the photo means nothing to write, and no file rewritten for nothing.
        guard !metadata.isEmpty else { return (fileURL, metadata, false) }
        let restored = embedded.looksStripped
        do {
            let written = try metadataWriter.write(metadata, toFileAt: fileURL)
            if written != fileURL { try? FileManager.default.removeItem(at: fileURL) }
            return (written, metadata, restored)
        } catch {
            log(.warning, "Could not write metadata into \(name) (\(error.localizedDescription)); importing it as it was served")
            return (fileURL, metadata, restored)
        }
    }

    /// Keeps the configured Photos album in step with what has already been synced.
    ///
    /// Deleting an album in Photos does not delete its photos, and renaming the album in the
    /// settings leaves the old one behind. In both cases the photos are still in the library, so
    /// the ledger rightly refuses to sync them again and nothing at all would happen. Putting them
    /// back into the album is the repair: it costs one album lookup per pass and does nothing once
    /// the album matches what the ledger recorded.
    private func refileIntoAlbum(_ albumName: String?, photos: [LightroomPhoto], report: inout SyncReport) async {
        guard let albumName else { return }
        let synced = photos.compactMap { ledger.state.entries[$0.assetID] }
        guard !synced.isEmpty else { return }

        let albumMissing: Bool
        do {
            albumMissing = try await !photoLibrary.albumExists(named: albumName)
        } catch {
            log(.warning, "Could not check the album “\(albumName)”: \(error.localizedDescription)")
            return
        }

        // Only a missing album or a changed album name counts. A photo taken out of an album that
        // still exists was taken out on purpose, and is left alone.
        let stale = synced.filter { albumMissing || $0.photosAlbumName != albumName }
        var identifiers: [String] = []
        for entry in stale {
            if let identifier = entry.photosLocalIdentifier, !identifiers.contains(identifier) {
                identifiers.append(identifier)
            }
        }
        guard !identifiers.isEmpty else { return }

        do {
            let filed = Set(try await photoLibrary.addAssets(withIdentifiers: identifiers, toAlbumNamed: albumName))
            let assetIDs = stale
                .filter { $0.photosLocalIdentifier.map(filed.contains) ?? false }
                .map(\.assetID)
            try ledger.markFiled(assetIDs, inAlbum: albumName)
            report.refiled = assetIDs.count
            if !assetIDs.isEmpty {
                log(.info, "Put \(assetIDs.count) already-synced photo(s) back into “\(albumName)” because \(Self.refileReason(stale, albumName: albumName))")
            }
            if assetIDs.count < identifiers.count {
                log(.warning, "\(identifiers.count - assetIDs.count) synced photo(s) are no longer in the Photos library; they are not re-imported")
            }
        } catch {
            log(.warning, "Could not add photos to the album “\(albumName)”: \(error.localizedDescription)")
        }
    }

    /// Says why photos are being put back, which is what the log line has to explain.
    static func refileReason(_ stale: [LedgerEntry], albumName: String) -> String {
        if stale.allSatisfy({ $0.photosAlbumName == albumName }) {
            return "the album was missing"
        }
        if stale.contains(where: { $0.photosAlbumName != nil && $0.photosAlbumName != albumName }) {
            return "the album changed"
        }
        return "they were synced before the album was recorded"
    }

    /// What the Photos lookup came back with, and whether the library was asked at all. The two
    /// are separate so that a photo carrying too little to search on is not timed as a lookup.
    struct PhotosLookup {
        var identifier: String?
        var queried: Bool
    }

    /// Asks Photos whether this photo is already there, so a second Mac does not import it again.
    /// A lookup that fails is reported and treated as "not found": a duplicate is better than a
    /// photo that never syncs.
    private func findInPhotos(_ photo: LightroomPhoto, albumName: String?) async -> PhotosLookup {
        guard let fileName = photo.expectedPhotosFileName, let captureDate = photo.captureDate else {
            return PhotosLookup(identifier: nil, queried: false)
        }
        let query = PhotoMatchQuery(fileName: fileName, captureDate: captureDate,
                                    dateTolerance: Self.captureDateTolerance,
                                    pixelWidth: photo.croppedWidth, pixelHeight: photo.croppedHeight,
                                    albumName: albumName)
        do {
            return PhotosLookup(identifier: try await photoLibrary.findExistingAsset(matching: query), queried: true)
        } catch {
            log(.warning, "Could not check Photos for \(photo.fileName ?? photo.assetID): \(error.localizedDescription)")
            return PhotosLookup(identifier: nil, queried: true)
        }
    }

    static func chooseAlbum(from share: ShareInfo, preferred: String?) throws -> AlbumInfo {
        guard !share.albums.isEmpty else { throw SyncEngineError.noAlbums }
        if let preferred {
            guard let match = share.albums.first(where: { $0.id == preferred }) else {
                throw SyncEngineError.albumNotFound(preferred)
            }
            return match
        }
        return share.albums[0]
    }

    private func log(_ level: LogLevel, _ message: String) {
        sink?.log(level, message)
    }
}
