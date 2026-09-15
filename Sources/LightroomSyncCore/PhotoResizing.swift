import Foundation

/// Shrinks a downloaded photo before it is imported into Photos.
///
/// Lightroom serves whatever size it rendered, which for anything above the smallest setting is
/// the full-size file. Capping the long edge here is what keeps a synced album small enough for
/// iCloud to carry quickly. Implemented with ImageIO on macOS; the core library stays free of it
/// so the sync logic keeps building and testing on Linux.
public protocol PhotoResizing {
    /// Rewrites the image so that neither edge is longer than `maxLongEdge`, keeping its metadata
    /// and colour profile.
    ///
    /// Returns the file to import: the same URL when the photo is already small enough, or a new
    /// file next to it. Throwing is allowed and not fatal — the caller then imports the photo at
    /// the size it was served, which is better than not syncing it at all.
    func resized(fileAt url: URL, maxLongEdge: Int) throws -> URL
}

/// Leaves every photo at the size Lightroom served it. Used where no image toolkit is available:
/// the sync engine's own tests, and anything running off a Mac.
public struct NoPhotoResizing: PhotoResizing {
    public init() {}

    public func resized(fileAt url: URL, maxLongEdge: Int) throws -> URL { url }
}
