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
