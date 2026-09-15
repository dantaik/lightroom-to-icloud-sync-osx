#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import LightroomSyncCore
import UniformTypeIdentifiers

enum ImageMetadataError: Error, LocalizedError {
    case unreadable(URL)
    case couldNotWrite(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not read the image at \(url.lastPathComponent)."
        case .couldNotWrite(let url):
            return "Could not write \(url.lastPathComponent) with its metadata."
        }
    }
}

/// Reads and writes a photo's EXIF, IPTC and GPS with ImageIO.
///
/// The image data is copied from the source to the destination as it stands — ImageIO rewrites the
/// metadata segments around it and never re-encodes the pixels — so a photo can be described
/// without paying a generation of JPEG quality for it.
struct ImageMetadataWriter: PhotoMetadataWriting {
    func embeddedMetadata(fileAt url: URL) -> EmbeddedPhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return EmbeddedPhotoMetadata() }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        let captureDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
        let make = tiff[kCGImagePropertyTIFFMake] as? String
        let model = tiff[kCGImagePropertyTIFFModel] as? String

        return EmbeddedPhotoMetadata(
            captureTimeZoneOffset: EXIFTime.offsetSeconds(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String),
            hasCaptureDate: !(captureDate ?? "").isEmpty,
            hasCameraInfo: !(make ?? "").isEmpty || !(model ?? "").isEmpty,
            hasLocation: gps[kCGImagePropertyGPSLatitude] != nil && gps[kCGImagePropertyGPSLongitude] != nil
        )
    }

    func write(_ metadata: PhotoMetadata, toFileAt url: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ImageMetadataError.unreadable(url)
        }
        let existing = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let merged = Self.merging(metadata, into: existing) else { return url }

        let type = CGImageSourceGetType(source) ?? (UTType.jpeg.identifier as CFString)
        let destinationURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-described")
            .appendingPathExtension(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type, 1, nil) else {
            throw ImageMetadataError.couldNotWrite(destinationURL)
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, merged as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ImageMetadataError.couldNotWrite(destinationURL)
        }
        return destinationURL
    }

    // MARK: - Merging

    /// Lightroom's metadata folded into what the file already says, or nil when the file already
    /// said all of it.
    ///
    /// The file wins wherever it has a value: what a camera wrote into the original is the most
    /// authoritative account of the photo there is, and Lightroom's copy of it has been through
    /// Adobe's JSON on the way here. The one exception is the capture time, which is written from
    /// the value Photos is also given, so that the file and the library cannot disagree about when
    /// the photo was taken.
    static func merging(_ metadata: PhotoMetadata, into existing: [CFString: Any]) -> [CFString: Any]? {
        var properties = existing
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        var gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        var changed = false

        func fill(_ dictionary: inout [CFString: Any], _ key: CFString, _ value: Any?) {
            guard let value, isEmpty(dictionary[key]) else { return }
            dictionary[key] = value
            changed = true
        }
        func set(_ dictionary: inout [CFString: Any], _ key: CFString, _ value: Any?) {
            guard let value, !equal(dictionary[key], value) else { return }
            dictionary[key] = value
            changed = true
        }

        if let captureDate = metadata.captureDate {
            let zone = metadata.captureTimeZoneOffset.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
            set(&exif, kCGImagePropertyExifDateTimeOriginal, EXIFTime.timestamp(captureDate, in: zone))
            fill(&exif, kCGImagePropertyExifDateTimeDigitized, EXIFTime.timestamp(captureDate, in: zone))
            fill(&tiff, kCGImagePropertyTIFFDateTime, EXIFTime.timestamp(captureDate, in: zone))
            if let offset = metadata.captureTimeZoneOffset {
                set(&exif, kCGImagePropertyExifOffsetTimeOriginal, EXIFTime.offsetTag(offset))
                fill(&exif, kCGImagePropertyExifOffsetTime, EXIFTime.offsetTag(offset))
            }
        }

        fill(&tiff, kCGImagePropertyTIFFMake, metadata.cameraMake)
        fill(&tiff, kCGImagePropertyTIFFModel, metadata.cameraModel)
        fill(&tiff, kCGImagePropertyTIFFArtist, metadata.creator)
        fill(&tiff, kCGImagePropertyTIFFCopyright, metadata.copyright)
        fill(&tiff, kCGImagePropertyTIFFImageDescription, metadata.caption)

        fill(&exif, kCGImagePropertyExifLensModel, metadata.lens)
        fill(&exif, kCGImagePropertyExifISOSpeedRatings, metadata.iso.map { [$0] })
        fill(&exif, kCGImagePropertyExifFNumber, metadata.fNumber)
        fill(&exif, kCGImagePropertyExifExposureTime, metadata.exposureTime)
        fill(&exif, kCGImagePropertyExifFocalLength, metadata.focalLength)

        // Photos reads the IPTC caption into the caption field of the asset it creates. It has no
        // use for keywords or a title, which PhotoKit cannot set either, but they stay with the
        // file, so they survive an export and anything else that reads the photo.
        fill(&iptc, kCGImagePropertyIPTCObjectName, metadata.title)
        fill(&iptc, kCGImagePropertyIPTCCaptionAbstract, metadata.caption)
        fill(&iptc, kCGImagePropertyIPTCKeywords, metadata.keywords.isEmpty ? nil : metadata.keywords)
        fill(&iptc, kCGImagePropertyIPTCByline, metadata.creator.map { [$0] })
        fill(&iptc, kCGImagePropertyIPTCCopyrightNotice, metadata.copyright)
        fill(&iptc, kCGImagePropertyIPTCStarRating, metadata.rating)

        if let location = metadata.location, isEmpty(gps[kCGImagePropertyGPSLatitude]) {
            gps[kCGImagePropertyGPSLatitude] = abs(location.latitude)
            gps[kCGImagePropertyGPSLatitudeRef] = location.latitude < 0 ? "S" : "N"
            gps[kCGImagePropertyGPSLongitude] = abs(location.longitude)
            gps[kCGImagePropertyGPSLongitudeRef] = location.longitude < 0 ? "W" : "E"
            if let altitude = location.altitude {
                gps[kCGImagePropertyGPSAltitude] = abs(altitude)
                // 0 is above sea level, 1 below; there is no sign in the tag itself.
                gps[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
            }
            changed = true
        }

        guard changed else { return nil }
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary] = iptc }
        if !gps.isEmpty { properties[kCGImagePropertyGPSDictionary] = gps }
        return properties
    }

    /// Treats a missing value and an empty string as the same thing: a tag with nothing in it is
    /// a gap to fill, not a value the file is asserting.
    private static func isEmpty(_ value: Any?) -> Bool {
        guard let value else { return true }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespaces).isEmpty }
        if let list = value as? [Any] { return list.isEmpty }
        return false
    }

    /// Whether the file already holds this exact value, so that writing it would be a no-op.
    /// Everything these dictionaries carry bridges to an NSObject — strings to NSString, numbers
    /// to NSNumber — and anything that does not is treated as different and written.
    private static func equal(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let existing = lhs as? NSObject, let incoming = rhs as? NSObject else { return false }
        return existing == incoming
    }

}
#endif
