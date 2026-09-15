#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import LightroomSyncCore
import UniformTypeIdentifiers

enum ImageResizeError: Error, LocalizedError {
    case unreadable(URL)
    case couldNotScale(URL)
    case couldNotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read the image at \(url.lastPathComponent)."
        case .couldNotScale(let url):
            return "Could not scale \(url.lastPathComponent) down."
        case .couldNotWrite(let url):
            return "Could not write the scaled image to \(url.lastPathComponent)."
        }
    }
}

/// Shrinks a downloaded photo with ImageIO, keeping its EXIF, its XMP and its colour profile.
///
/// ImageIO scales while it decodes rather than decoding the whole image first, so a 60 MP JPEG
/// costs little to bring down to a screen's worth of pixels.
struct ImageResizer: PhotoResizing {
    /// High enough that the scaled photo is indistinguishable from the render Lightroom sent,
    /// low enough that the file is a fraction of its size. This is about what Lightroom's own
    /// gallery renditions use.
    static let jpegQuality = 0.9

    func resized(fileAt url: URL, maxLongEdge: Int) throws -> URL {
        guard maxLongEdge > 0 else { return url }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ImageResizeError.unreadable(url)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // Already small enough: hand back the file as it is rather than re-encoding it, which
        // would cost a generation of JPEG quality for nothing.
        if width > 0, height > 0, max(width, height) <= maxLongEdge { return url }

        // The photo keeps the orientation it was stored with, and the EXIF tag that describes it
        // is copied below, so the two stay in step. Transforming here would contradict the tag.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageResizeError.couldNotScale(url)
        }

        let destinationURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(maxLongEdge)")
            .appendingPathExtension("jpg")
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL,
                                                                UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageResizeError.couldNotWrite(destinationURL)
        }
        CGImageDestinationAddImage(destination, image, Self.properties(from: properties, for: image) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ImageResizeError.couldNotWrite(destinationURL)
        }
        return destinationURL
    }

    /// The metadata to write: everything the download carried, with the sizes corrected to the
    /// scaled image. Lightroom embeds EXIF, XMP and an ICC profile, and a photo that arrives in
    /// Photos without them has lost its camera, its capture time and its colours.
    static func properties(from source: [CFString: Any], for image: CGImage) -> [CFString: Any] {
        var properties = source
        properties[kCGImagePropertyPixelWidth] = image.width
        properties[kCGImagePropertyPixelHeight] = image.height
        properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        return properties
    }
}
#endif
