import Foundation

public struct SyncConfiguration: Equatable {
    public var shareLink: String
    public var preferredAlbumID: String?
    public var photosAlbumName: String?
    public var checkInterval: TimeInterval
    /// How large the synced photos should be.
    public var photoSize: PhotoSize
    public var ignoreDelays: Bool

    public init(shareLink: String, preferredAlbumID: String? = nil, photosAlbumName: String? = nil,
                checkInterval: TimeInterval, photoSize: PhotoSize = .default, ignoreDelays: Bool = false) {
        self.shareLink = shareLink
        self.preferredAlbumID = preferredAlbumID
        self.photosAlbumName = photosAlbumName
        self.checkInterval = checkInterval
        self.photoSize = photoSize
        self.ignoreDelays = ignoreDelays
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
    public var startedAt: Date
    public var finishedAt: Date

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

/// Receives progress and log lines from a sync pass. Called from arbitrary threads.
public protocol SyncEventSink: AnyObject {
    func log(_ level: LogLevel, _ message: String)
    func progress(completed: Int, total: Int)
}

public enum SyncEngineError: Error, LocalizedError, Equatable {
    case invalidShareLink(String)
    case noAlbums
    case albumNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidShareLink(let detail): return detail
        case .noAlbums: return "This share contains no albums."
        case .albumNotFound(let id): return "The selected album (\(id)) is no longer part of this share."
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
    private let downloadDirectory: URL
    private let settleTime: TimeInterval
    private weak var sink: SyncEventSink?

    /// How far a Photos asset's creation date may differ from Lightroom's capture date and still
    /// be the same photo. Lightroom reports capture times without a zone, so two Macs in different
    /// time zones read the same photo as up to a day apart.
    public static let captureDateTolerance: TimeInterval = 26 * 3600

    public init(client: LightroomGalleryClient, ledger: Ledger, importer: PhotoImporting,
                photoLibrary: PhotoLibraryAccess = NullPhotoLibraryAccess(),
                resizer: PhotoResizing = NoPhotoResizing(),
                downloadDirectory: URL, settleTime: TimeInterval = SyncPolicy.defaultSettleTime,
                sink: SyncEventSink?) {
        self.client = client
        self.ledger = ledger
        self.importer = importer
        self.photoLibrary = photoLibrary
        self.resizer = resizer
        self.downloadDirectory = downloadDirectory
        self.settleTime = settleTime
        self.sink = sink
    }

    public func run(_ config: SyncConfiguration, now: Date = Date()) async throws -> SyncReport {
        let link: AlbumShareLink
        do {
            link = try AlbumShareLink.parse(config.shareLink)
        } catch {
            throw SyncEngineError.invalidShareLink(error.localizedDescription)
        }
        let (shareID, linkAlbumID) = try await client.resolve(link)
        let share = try await client.fetchShare(shareID: shareID)
        let album = try Self.chooseAlbum(from: share, preferred: config.preferredAlbumID ?? linkAlbumID)
        var report = SyncReport(shareID: shareID, albumID: album.id, albumName: album.name, startedAt: now)

        guard share.downloadsAllowed else { throw LightroomError.downloadsDisabled }

        let photos = try await client.listPhotos(shareID: shareID, albumID: album.id).filter(\.isImage)
        report.photosInAlbum = photos.count
        let candidates = photos.filter { !ledger.contains(assetID: $0.assetID) }
        report.alreadySynced = photos.count - candidates.count
        let policy = SyncPolicy(minimumAgeInAlbum: config.checkInterval, settleTime: settleTime, ignoreDelays: config.ignoreDelays)
        let albumName = config.photosAlbumName.flatMap { $0.isEmpty ? nil : $0 }
        log(.info, "Album “\(album.name)”: \(photos.count) photos, \(candidates.count) not yet synced, at \(config.photoSize.shortDescription)")
        await refileIntoAlbum(albumName, photos: photos, report: &report)
        sink?.progress(completed: 0, total: candidates.count)

        for (index, photo) in candidates.enumerated() {
            defer { sink?.progress(completed: index + 1, total: candidates.count) }
            try Task.checkCancellation()
            let name = photo.fileName ?? photo.assetID

            if let sha = photo.originalSHA256, let existing = ledger.entry(withOriginalSHA256: sha) {
                var duplicate = existing
                duplicate.assetID = photo.assetID
                duplicate.shareID = shareID
                duplicate.albumID = album.id
                duplicate.syncedAt = now
                try ledger.record(duplicate)
                report.duplicates += 1
                log(.info, "Skipping \(name): the same original was already synced")
                continue
            }

            if let identifier = await findInPhotos(photo, albumName: albumName) {
                try ledger.record(LedgerEntry(assetID: photo.assetID, shareID: shareID, albumID: album.id,
                                              fileName: photo.expectedPhotosFileName ?? photo.fileName,
                                              originalSHA256: photo.originalSHA256,
                                              photosLocalIdentifier: identifier, photosAlbumName: albumName,
                                              syncedAt: now, captureDate: photo.captureDate,
                                              pixelWidth: nil, pixelHeight: nil, downgraded: false))
                report.foundInPhotos += 1
                log(.info, "\(name) is already in Photos; recorded it without downloading")
                continue
            }

            let firstSeen = try ledger.noteSeen(assetID: photo.assetID, at: now)
            if case .wait(let reason) = policy.decision(for: photo, firstSeen: firstSeen, now: now) {
                report.pending += 1
                log(.info, "Waiting on \(name): \(reason)")
                continue
            }

            let downloaded: DownloadedPhoto
            do {
                downloaded = try await download(photo, shareID: shareID, size: config.photoSize, name: name)
            } catch LightroomError.downloadsDisabled {
                throw LightroomError.downloadsDisabled
            } catch {
                report.failed += 1
                log(.error, "Download failed for \(name): \(error.localizedDescription)")
                continue
            }

            // What Lightroom served is measured against what the chosen size asks for, not against
            // the edited photo: a photo held back by the size setting is doing what it was told.
            let servedSize = JPEGInfo.pixelSize(ofFileAt: downloaded.fileURL)
            var downgraded = false
            if let servedSize,
               let intended = config.photoSize.intendedLongEdge(editedLongEdge: photo.expectedLongEdge),
               servedSize.longEdge + 2 < intended {
                downgraded = true
                report.downgraded += 1
                log(.warning, "\(name): Lightroom served \(servedSize.width)×\(servedSize.height) but the edited photo is \(photo.croppedWidth ?? 0)×\(photo.croppedHeight ?? 0). Photos synced from Lightroom Classic only have smart previews in the cloud.")
            }

            let fileURL = shrink(downloaded.fileURL, servedSize: servedSize, to: config.photoSize, name: name)
            if fileURL != downloaded.fileURL { try? FileManager.default.removeItem(at: downloaded.fileURL) }
            let size = fileURL == downloaded.fileURL ? servedSize : (JPEGInfo.pixelSize(ofFileAt: fileURL) ?? servedSize)
            // Lightroom serves a JPEG named after the original, and a rendition carries no name at
            // all, so the name it takes in Photos is the one the ledger and a second Mac look for.
            let fileName = downloaded.fileName ?? photo.expectedPhotosFileName ?? photo.fileName

            let request = PhotoImportRequest(fileURL: fileURL,
                                             originalFileName: fileName,
                                             captureDate: photo.captureDate,
                                             albumName: albumName)
            let localIdentifier: String
            do {
                localIdentifier = try await importer.importPhoto(request)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                report.failed += 1
                log(.error, "Import into Photos failed for \(name): \(error.localizedDescription)")
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)

            try ledger.record(LedgerEntry(assetID: photo.assetID, shareID: shareID, albumID: album.id,
                                          fileName: fileName,
                                          originalSHA256: photo.originalSHA256,
                                          photosLocalIdentifier: localIdentifier, photosAlbumName: albumName,
                                          syncedAt: now, captureDate: photo.captureDate,
                                          pixelWidth: size?.width, pixelHeight: size?.height,
                                          downgraded: downgraded))
            report.synced += 1
            let dimensions = size.map { " (\($0.width)×\($0.height))" } ?? ""
            log(.info, "Synced \(name)\(dimensions)")
        }

        report.finishedAt = Date()
        return report
    }

    /// Fetches a photo at the chosen size.
    ///
    /// When Lightroom already holds a rendition of that size, that is what is fetched: it is
    /// served as it stands, while the full-size file is rendered on demand and is many times
    /// larger. Any bigger size has to come from the download host and is shrunk afterwards.
    /// A rendition that cannot be fetched is not a failure; the full-size download still works.
    private func download(_ photo: LightroomPhoto, shareID: String, size: PhotoSize, name: String) async throws -> DownloadedPhoto {
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

    /// Asks Photos whether this photo is already there, so a second Mac does not import it again.
    /// A lookup that fails is reported and treated as "not found": a duplicate is better than a
    /// photo that never syncs.
    private func findInPhotos(_ photo: LightroomPhoto, albumName: String?) async -> String? {
        guard let fileName = photo.expectedPhotosFileName, let captureDate = photo.captureDate else {
            return nil
        }
        let query = PhotoMatchQuery(fileName: fileName, captureDate: captureDate,
                                    dateTolerance: Self.captureDateTolerance,
                                    pixelWidth: photo.croppedWidth, pixelHeight: photo.croppedHeight,
                                    albumName: albumName)
        do {
            return try await photoLibrary.findExistingAsset(matching: query)
        } catch {
            log(.warning, "Could not check Photos for \(photo.fileName ?? photo.assetID): \(error.localizedDescription)")
            return nil
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
