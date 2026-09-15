import Foundation

/// A photo file taken from Lightroom's own library on this Mac instead of downloaded.
public struct LocalPhotoFile: Equatable {
    public let fileURL: URL
    public let fileName: String?
    public let contentType: String?
    public let byteCount: Int
    /// The long edge of the file served, so a pass can say what it used and the engine can check
    /// it against the size that was asked for.
    public let longEdge: Int?
    /// When Lightroom rendered this file. A file older than the photo's last edit is a picture of
    /// an earlier version of it; see ``SyncEngine`` for what happens to one.
    public let renderedAt: Date?
    /// Where in the library it came from, for the log. Not a path: a short description such as
    /// "preview, 2048 px".
    public let source: String

    public init(fileURL: URL, fileName: String?, contentType: String?, byteCount: Int,
                longEdge: Int?, renderedAt: Date?, source: String) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.contentType = contentType
        self.byteCount = byteCount
        self.longEdge = longEdge
        self.renderedAt = renderedAt
        self.source = source
    }
}

/// A source of already-rendered photo files on this Mac, tried before anything is downloaded.
///
/// Lightroom keeps its library on the machine it runs on, and a file it has already rendered
/// costs nothing to copy. What it holds, though, is not interchangeable with what the download
/// host serves, and the difference is the whole point of this app:
///
/// - **Originals** are the files as they came off the camera. The edits are not in them — they are
///   Camera Raw develop settings, and applying those needs Adobe's rendering engine, which is the
///   one thing this app cannot borrow. Importing an original would put a photo into Photos that
///   does not look like the one in Lightroom, so an original is never substituted for a download.
/// - **Previews** are rendered with the edits applied, so they are usable. They are built for the
///   screen, though, so one only stands in for a size it actually covers.
///
/// An implementation returns nil for anything it cannot serve under those rules, and the pass
/// downloads the photo exactly as it did before.
public protocol LocalPhotoSource {
    /// A file for this photo that carries the edits Lightroom shows and is at least
    /// `minimumLongEdge` on its long edge, copied into `directory`.
    ///
    /// Returns nil whenever the library has nothing that qualifies — which is the common answer,
    /// and not an error.
    func localFile(for photo: LightroomPhoto, minimumLongEdge: Int,
                   to directory: URL) async throws -> LocalPhotoFile?
}

/// The default: no local library, every photo downloaded. What the app does on a Mac where
/// Lightroom is not installed, and what it did before a local source existed.
public struct NoLocalPhotoSource: LocalPhotoSource {
    public init() {}

    public func localFile(for photo: LightroomPhoto, minimumLongEdge: Int,
                          to directory: URL) async throws -> LocalPhotoFile? { nil }
}
