import Foundation

/// Where a photo was taken, in decimal degrees. Plain numbers rather than CoreLocation, which the
/// core library cannot import and Linux does not have.
public struct PhotoLocation: Equatable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    /// A location only when the numbers describe a real place: in range, finite, and not the
    /// zeroes a stripped GPS block decodes to, which would drop the photo into the Atlantic.
    ///
    /// Deliberately not an initializer. `PhotoLocation(latitude: 0, longitude: 0)` would resolve
    /// to the memberwise one above and quietly skip the checks.
    public static func validated(latitude: Double?, longitude: Double?, altitude: Double? = nil) -> PhotoLocation? {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              latitude != 0 || longitude != 0
        else { return nil }
        return PhotoLocation(latitude: latitude, longitude: longitude,
                             altitude: altitude.flatMap { $0.isFinite ? $0 : nil })
    }
}

/// What Lightroom knows about a photo besides its pixels.
///
/// Lightroom serves a JPEG that carries most of this already, but only for the full-size download:
/// the 2048 px rendition the Small size uses is a preview Adobe generates, and what survives in it
/// is Adobe's business, not ours. Carrying the album listing's own copy of the metadata means the
/// photo reaches Photos described the same way whichever size it was synced at.
public struct PhotoMetadata: Equatable {
    /// When the photo was taken. Resolved against the file's own time zone by ``CaptureTime``
    /// before it is written, because Lightroom reports capture times without a zone.
    public var captureDate: Date?
    /// Seconds east of UTC that ``captureDate`` was resolved in, when it is known.
    public var captureTimeZoneOffset: Int?

    public var title: String?
    public var caption: String?
    public var keywords: [String]
    public var creator: String?
    public var copyright: String?

    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?

    public var iso: Int?
    public var fNumber: Double?
    public var exposureTime: Double?
    public var focalLength: Double?

    public var location: PhotoLocation?
    /// Lightroom's star rating, 0 to 5.
    public var rating: Int?

    /// The rating from which a photo arrives in Photos as a Favourite. Four and five stars are the
    /// keepers in a Lightroom workflow; anything below that is a photo that survived a cull.
    public static let favoriteRatingThreshold = 4

    public var isFavorite: Bool {
        guard let rating else { return false }
        return rating >= Self.favoriteRatingThreshold
    }

    /// True when there is nothing here worth writing into a file.
    public var isEmpty: Bool {
        self == PhotoMetadata()
    }

    public init(captureDate: Date? = nil, captureTimeZoneOffset: Int? = nil,
                title: String? = nil, caption: String? = nil, keywords: [String] = [],
                creator: String? = nil, copyright: String? = nil,
                cameraMake: String? = nil, cameraModel: String? = nil, lens: String? = nil,
                iso: Int? = nil, fNumber: Double? = nil, exposureTime: Double? = nil,
                focalLength: Double? = nil, location: PhotoLocation? = nil, rating: Int? = nil) {
        self.captureDate = captureDate
        self.captureTimeZoneOffset = captureTimeZoneOffset
        self.title = title
        self.caption = caption
        self.keywords = keywords
        self.creator = creator
        self.copyright = copyright
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lens = lens
        self.iso = iso
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.focalLength = focalLength
        self.location = location
        self.rating = rating
    }
}

// MARK: - Reading Lightroom's copy

public extension PhotoMetadata {
    /// Picks the metadata out of an asset's payload.
    ///
    /// Every field is optional and every one is read defensively: a share exposes whatever the
    /// photo happens to carry, and a photo straight off a camera has no title, no keywords and no
    /// GPS at all. Nothing here fails; a field that is missing or malformed is simply not set.
    init(payload: LightroomAsset.Payload?) {
        guard let payload else {
            self.init()
            return
        }
        let xmp = payload.xmp
        let exif = xmp?["exif"]
        let tiff = xmp?["tiff"]
        let dc = xmp?["dc"]

        self.init(
            title: dc?["title"]?.localizedString,
            caption: dc?["description"]?.localizedString,
            keywords: Self.keywords(in: dc?["subject"]),
            creator: dc?["creator"]?.localizedString,
            copyright: dc?["rights"]?.localizedString,
            cameraMake: tiff?["Make"]?.localizedString,
            cameraModel: tiff?["Model"]?.localizedString,
            lens: xmp?.path("aux", "Lens")?.localizedString ?? exif?["LensModel"]?.localizedString,
            iso: Self.iso(in: exif),
            fNumber: exif?["FNumber"]?.rational,
            exposureTime: exif?["ExposureTime"]?.rational,
            focalLength: exif?["FocalLength"]?.rational,
            location: Self.location(payload: payload, exif: exif),
            rating: Self.rating(payload: payload, xmp: xmp)
        )
    }

    /// Keywords, deduplicated and in a stable order so two syncs write the same file.
    private static func keywords(in subject: JSONValue?) -> [String] {
        guard let subject else { return [] }
        var seen: Set<String> = []
        return subject.stringList
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func iso(in exif: JSONValue?) -> Int? {
        // ISOSpeedRatings is an XMP sequence even when the camera recorded one value.
        guard let value = exif?["ISOSpeedRatings"] ?? exif?["ISOSpeed"] ?? exif?["PhotographicSensitivity"] else {
            return nil
        }
        if let first = value.array?.first { return first.int }
        return value.int
    }

    /// Lightroom's own location record first — it is decimal degrees and the user may have placed
    /// it by hand on the map — then whatever GPS the original file carried in its XMP.
    private static func location(payload: LightroomAsset.Payload, exif: JSONValue?) -> PhotoLocation? {
        if let location = payload.location,
           let resolved = PhotoLocation.validated(latitude: location.latitude, longitude: location.longitude,
                                                  altitude: location.altitude) {
            return resolved
        }
        return PhotoLocation.validated(latitude: GPSCoordinate.parse(exif?["GPSLatitude"]),
                                       longitude: GPSCoordinate.parse(exif?["GPSLongitude"]),
                                       altitude: exif?["GPSAltitude"]?.rational)
    }

    /// The star rating, from the XMP packet or from the share's own ratings map.
    ///
    /// `payload.ratings` is keyed by the Adobe user who set it. A shared album has one owner in
    /// practice, and taking the highest is the reading that does not depend on dictionary order.
    private static func rating(payload: LightroomAsset.Payload, xmp: JSONValue?) -> Int? {
        if let rating = xmp?.path("xmp", "Rating")?.int, (0...5).contains(rating) { return rating }
        guard case .object(let members)? = payload.ratings else { return nil }
        let ratings = members.values.compactMap { $0["rating"]?.int ?? $0.int }.filter { (0...5).contains($0) }
        return ratings.max()
    }
}

/// Parses the coordinate formats XMP uses for GPS.
///
/// XMP writes a coordinate as degrees and decimal minutes with a hemisphere letter,
/// `"37,48.4783N"`, and older packets use degrees, minutes and seconds, `"37,48,28.7N"`.
/// Lightroom sometimes sends a plain signed number instead.
enum GPSCoordinate {
    static func parse(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        if case .number(let degrees) = value { return degrees }
        guard let text = value.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let degrees = Double(text) { return degrees }

        var body = text
        var sign = 1.0
        if let hemisphere = body.last, "NSEWnsew".contains(hemisphere) {
            if hemisphere == "S" || hemisphere == "s" || hemisphere == "W" || hemisphere == "w" { sign = -1 }
            body.removeLast()
        }
        let parts = body.split(separator: ",").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        guard values.allSatisfy({ $0 >= 0 }) else { return nil }
        switch values.count {
        case 1: return sign * values[0]
        case 2: return sign * (values[0] + values[1] / 60)
        case 3: return sign * (values[0] + values[1] / 60 + values[2] / 3600)
        default: return nil
        }
    }
}

// MARK: - Capture time

/// Turns Lightroom's capture date into the instant the shutter actually fired.
///
/// Lightroom reports `captureDate` the way EXIF does, as a wall-clock reading with no time zone:
/// `2024-09-18T15:55:12` is "a quarter to four in the afternoon", but not where. Reading it in the
/// zone the syncing Mac happens to be in puts a photo shot in Tokyo eight hours out when it is
/// synced from California. The downloaded file usually knows better — EXIF 2.31 records the zone
/// the camera was set to in `OffsetTimeOriginal` — so that is what it is read in when it is there.
public enum CaptureTime {
    public struct Resolved: Equatable {
        public let date: Date?
        /// Seconds east of UTC the reading was interpreted in, or nil when nothing said.
        public let offsetSeconds: Int?

        public init(date: Date?, offsetSeconds: Int?) {
            self.date = date
            self.offsetSeconds = offsetSeconds
        }
    }

    public static func resolve(rawCaptureDate: String?, embeddedOffsetSeconds: Int?,
                               localTimeZone: TimeZone = .current) -> Resolved {
        guard let embeddedOffsetSeconds, let zone = TimeZone(secondsFromGMT: embeddedOffsetSeconds) else {
            return Resolved(date: AdobeDate.parse(rawCaptureDate, localTimeZone: localTimeZone), offsetSeconds: nil)
        }
        // A timestamp that names its own zone is already an instant; the offset is only ever used
        // to give a zone to a reading that has none.
        return Resolved(date: AdobeDate.parse(rawCaptureDate, localTimeZone: zone),
                        offsetSeconds: AdobeDate.hasExplicitZone(rawCaptureDate) ? nil : embeddedOffsetSeconds)
    }
}

/// The two formats EXIF uses for time, which the metadata writer reads and writes.
///
/// They live here rather than beside the ImageIO code so that they are covered by the core test
/// suite: a wrong format string writes a tag every other program then misreads, and nothing about
/// the parsing or the formatting needs an image toolkit to check.
public enum EXIFTime {
    /// `2024:09:18 15:55:12` — a wall-clock reading in the zone the camera was set to.
    public static func timestamp(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// `OffsetTimeOriginal` as EXIF 2.31 spells it: `+09:00`, or `-03:30`.
    public static func offsetTag(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    /// Reads that tag back. Rejects anything outside the offsets a real time zone can have.
    public static func offsetSeconds(_ tag: String?) -> Int? {
        guard let tag = tag?.trimmingCharacters(in: .whitespaces), let sign = tag.first,
              sign == "+" || sign == "-" else { return nil }
        let body = tag.dropFirst().replacingOccurrences(of: ":", with: "")
        guard body.count == 4, let hours = Int(body.prefix(2)), let minutes = Int(body.suffix(2)),
              hours <= 14, minutes < 60 else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return sign == "-" ? -seconds : seconds
    }
}
