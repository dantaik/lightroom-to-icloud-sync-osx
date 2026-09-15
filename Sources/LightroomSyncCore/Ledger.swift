import Foundation

/// One photo that has been imported into Photos.
public struct LedgerEntry: Codable, Equatable {
    public var assetID: String
    public var shareID: String
    public var albumID: String
    public var fileName: String?
    public var originalSHA256: String?
    /// SHA-256 of the downloaded picture with every metadata segment left out, as
    /// ``PhotoContentHash`` computes it. Absent in ledgers written before this was tracked, and in
    /// entries for photos that were never downloaded because Photos already held them.
    public var contentSHA256: String?
    public var photosLocalIdentifier: String?
    /// The Photos album the photo was filed into, so a later change of album can be repaired.
    /// Absent in ledgers written before this was tracked, which reads as "album unknown".
    public var photosAlbumName: String?
    public var syncedAt: Date
    public var captureDate: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// True when Lightroom served a smaller rendition than the edited photo's size.
    public var downgraded: Bool

    public init(assetID: String, shareID: String, albumID: String, fileName: String?, originalSHA256: String?,
                contentSHA256: String? = nil, photosLocalIdentifier: String?, photosAlbumName: String? = nil,
                syncedAt: Date, captureDate: Date?, pixelWidth: Int?, pixelHeight: Int?, downgraded: Bool) {
        self.assetID = assetID
        self.shareID = shareID
        self.albumID = albumID
        self.fileName = fileName
        self.originalSHA256 = originalSHA256
        self.contentSHA256 = contentSHA256
        self.photosLocalIdentifier = photosLocalIdentifier
        self.photosAlbumName = photosAlbumName
        self.syncedAt = syncedAt
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.downgraded = downgraded
    }
}

public struct LedgerState: Codable, Equatable {
    /// Synced photos keyed by Lightroom asset ID.
    public var entries: [String: LedgerEntry]
    /// When each not-yet-synced photo was first observed in the album, keyed by asset ID.
    public var firstSeen: [String: Date]

    public init(entries: [String: LedgerEntry] = [:], firstSeen: [String: Date] = [:]) {
        self.entries = entries
        self.firstSeen = firstSeen
    }
}

/// Persistent record of what has already been synced. A photo listed here is never synced again.
public final class Ledger {
    public let fileURL: URL
    public private(set) var state: LedgerState

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            state = try Self.decoder.decode(LedgerState.self, from: data)
        } else {
            state = LedgerState()
        }
    }

    public var syncedCount: Int { state.entries.count }

    public func contains(assetID: String) -> Bool {
        state.entries[assetID] != nil
    }

    public func entry(withOriginalSHA256 sha256: String) -> LedgerEntry? {
        state.entries.values.first { $0.originalSHA256 == sha256 }
    }

    /// A synced photo whose downloaded picture is byte-for-byte this one, metadata aside.
    ///
    /// The last word on whether two assets are one photograph, and the only one that needs no
    /// file name, capture time or hash from Lightroom to say so. It can only be asked once a photo
    /// has been downloaded, so it settles nothing before the fetch; see ``PhotoContentHash``.
    public func entry(withContentSHA256 sha256: String) -> LedgerEntry? {
        state.entries.values.first { $0.contentSHA256 == sha256 }
    }

    /// A synced photo that is the same photograph as this one: the same original file name, and a
    /// capture time within `tolerance` of it.
    ///
    /// This is the identity the Photos lookup searches the library on, kept in the ledger too.
    /// Lightroom reports no `sha256` for some assets and a different one for each copy of others,
    /// so the hash alone leaves the same photograph looking new; when it does, this is what
    /// answers, without Photos having to be asked at all.
    public func entry(withFileName fileName: String, captureDate: Date,
                      tolerance: TimeInterval) -> LedgerEntry? {
        state.entries.values.first { entry in
            guard let name = entry.fileName,
                  name.caseInsensitiveCompare(fileName) == .orderedSame,
                  let date = entry.captureDate
            else { return false }
            return abs(date.timeIntervalSince(captureDate)) <= tolerance
        }
    }

    /// Records the first time a photo was observed. Returns the stored date (existing or new).
    @discardableResult
    public func noteSeen(assetID: String, at date: Date) throws -> Date {
        if let existing = state.firstSeen[assetID] { return existing }
        state.firstSeen[assetID] = date
        try save()
        return date
    }

    /// Notes that these photos are now in `albumName`, after they were put back into it.
    public func markFiled(_ assetIDs: [String], inAlbum albumName: String?) throws {
        var changed = false
        for assetID in assetIDs where state.entries[assetID] != nil {
            guard state.entries[assetID]?.photosAlbumName != albumName else { continue }
            state.entries[assetID]?.photosAlbumName = albumName
            changed = true
        }
        if changed { try save() }
    }

    public func record(_ entry: LedgerEntry) throws {
        state.entries[entry.assetID] = entry
        state.firstSeen[entry.assetID] = nil
        try save()
    }

    public func save() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
