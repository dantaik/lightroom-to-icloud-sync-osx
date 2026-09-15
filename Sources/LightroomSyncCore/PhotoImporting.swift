import Foundation

public struct PhotoImportRequest: Equatable {
    public let fileURL: URL
    public let originalFileName: String?
    public let captureDate: Date?
    /// Name of the Photos album to add the photo to; nil adds it to the library only.
    public let albumName: String?

    public init(fileURL: URL, originalFileName: String?, captureDate: Date?, albumName: String?) {
        self.fileURL = fileURL
        self.originalFileName = originalFileName
        self.captureDate = captureDate
        self.albumName = albumName
    }
}

/// Puts a downloaded photo into the Photos library. Implemented with PhotoKit on macOS.
public protocol PhotoImporting {
    /// Imports the file (the importer may move it) and returns the Photos local identifier.
    func importPhoto(_ request: PhotoImportRequest) async throws -> String
}

/// Describes the photo to look for in the Photos library.
///
/// The ledger of synced photos is local to one Mac, so on a second Mac every photo would look
/// new. Photos itself is the shared record: iCloud Photos has already put the assets on both
/// machines, so a photo that is present there has been synced before, whichever Mac did it.
public struct PhotoMatchQuery: Equatable {
    /// The original file name the photo would carry in Photos, e.g. `L1009709.jpg`.
    public let fileName: String
    /// Capture date of the photo according to Lightroom.
    public let captureDate: Date
    /// How far a Photos asset's creation date may differ and still count as the same photo.
    /// Wide enough to absorb the two Macs reading the same local capture time in different zones.
    public let dateTolerance: TimeInterval
    /// Pixel size of the edited photo, when Lightroom reports it. Used to pick between several
    /// candidates, never to reject the only one (Lightroom Classic photos arrive at 2048 px).
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// The configured Photos album, if any. A matched asset missing from it is added to it.
    public let albumName: String?

    public init(fileName: String, captureDate: Date, dateTolerance: TimeInterval,
                pixelWidth: Int?, pixelHeight: Int?, albumName: String?) {
        self.fileName = fileName
        self.captureDate = captureDate
        self.dateTolerance = dateTolerance
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.albumName = albumName
    }
}

/// The parts of the Photos library the sync engine needs: finding a photo that is already there,
/// and keeping the configured album in step with what has been synced.
public protocol PhotoLibraryAccess {
    /// Returns the Photos local identifier of a matching asset, or nil when there is none.
    func findExistingAsset(matching query: PhotoMatchQuery) async throws -> String?

    /// Whether an album with this name exists in the library.
    func albumExists(named name: String) async throws -> Bool

    /// Adds these assets to the named album, creating the album if it is gone, and skipping the
    /// ones that are in it already. Returns the identifiers that are now in the album; identifiers
    /// of assets that no longer exist in the library are left out.
    func addAssets(withIdentifiers identifiers: [String], toAlbumNamed name: String) async throws -> [String]
}

/// A library that holds nothing, for callers that have no Photos library.
public struct NullPhotoLibraryAccess: PhotoLibraryAccess {
    public init() {}

    public func findExistingAsset(matching query: PhotoMatchQuery) async throws -> String? { nil }

    public func albumExists(named name: String) async throws -> Bool { false }

    public func addAssets(withIdentifiers identifiers: [String], toAlbumNamed name: String) async throws -> [String] { [] }
}
