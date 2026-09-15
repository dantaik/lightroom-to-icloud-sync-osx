import XCTest
@testable import LightroomSyncCore

final class PhotoMetadataTests: XCTestCase {
    // MARK: - Reading the payload

    /// The shape a well-filled Lightroom asset arrives in: XMP split by namespace, a title and a
    /// caption as language alternatives, keywords as a bag, exposure values as rationals.
    private func payload(_ json: String) throws -> LightroomAsset.Payload {
        try AdobeJSON.decode(LightroomAsset.Payload.self, from: Data(json.utf8))
    }

    func testReadsEveryFieldOutOfAFullPayload() throws {
        let metadata = PhotoMetadata(payload: try payload("""
        {
          "captureDate": "2024-09-18T15:55:12",
          "location": {"latitude": 35.6586, "longitude": 139.7454, "altitude": 17.5},
          "ratings": {"user-a": {"rating": 4}},
          "xmp": {
            "dc": {
              "title": {"x-default": "Tokyo Tower"},
              "description": {"x-default": "Late afternoon from the park"},
              "subject": ["Tokyo", "travel", "architecture"],
              "creator": ["Ansel Adams"],
              "rights": {"x-default": "© 2024 Ansel Adams"}
            },
            "tiff": {"Make": "NIKON CORPORATION", "Model": "NIKON Z 8"},
            "aux": {"Lens": "NIKKOR Z 24-70mm f/2.8 S"},
            "exif": {
              "FNumber": [28, 10],
              "ExposureTime": [1, 250],
              "FocalLength": [500, 10],
              "ISOSpeedRatings": [400]
            }
          }
        }
        """))

        XCTAssertEqual(metadata.title, "Tokyo Tower")
        XCTAssertEqual(metadata.caption, "Late afternoon from the park")
        XCTAssertEqual(metadata.keywords, ["Tokyo", "travel", "architecture"])
        XCTAssertEqual(metadata.creator, "Ansel Adams")
        XCTAssertEqual(metadata.copyright, "© 2024 Ansel Adams")
        XCTAssertEqual(metadata.cameraMake, "NIKON CORPORATION")
        XCTAssertEqual(metadata.cameraModel, "NIKON Z 8")
        XCTAssertEqual(metadata.lens, "NIKKOR Z 24-70mm f/2.8 S")
        XCTAssertEqual(metadata.iso, 400)
        XCTAssertEqual(metadata.fNumber ?? 0, 2.8, accuracy: 0.001)
        XCTAssertEqual(metadata.exposureTime ?? 0, 0.004, accuracy: 0.0001)
        XCTAssertEqual(metadata.focalLength ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(metadata.location, PhotoLocation(latitude: 35.6586, longitude: 139.7454, altitude: 17.5))
        XCTAssertEqual(metadata.rating, 4)
        XCTAssertTrue(metadata.isFavorite)
    }

    /// A photo straight off a camera has no title, no keywords and no GPS. Reading it must produce
    /// an empty description rather than failing, because most photos look like this.
    func testAPayloadWithNoMetadataReadsAsEmpty() throws {
        let metadata = PhotoMetadata(payload: try payload("""
        {"captureDate": "2024-05-01T10:20:30", "importSource": {"fileName": "DSC_0001.NEF"}}
        """))
        XCTAssertTrue(metadata.isEmpty)
        XCTAssertNil(metadata.location)
        XCTAssertNil(metadata.rating)
        XCTAssertFalse(metadata.isFavorite)
        XCTAssertTrue(PhotoMetadata(payload: nil).isEmpty)
    }

    /// Adobe varies these shapes between photos and between catalogs, so every one has to read.
    func testAcceptsTheOtherShapesAdobeSends() throws {
        let metadata = PhotoMetadata(payload: try payload("""
        {
          "xmp": {
            "dc": {"title": "Plain string title", "subject": "single-keyword"},
            "exif": {
              "FNumber": "28/10",
              "ISOSpeedRatings": 800,
              "LensModel": "RF 50mm F1.2 L USM",
              "GPSLatitude": "35,39.516N",
              "GPSLongitude": "139,44.724E"
            },
            "xmp": {"Rating": 5}
          }
        }
        """))
        XCTAssertEqual(metadata.title, "Plain string title")
        XCTAssertEqual(metadata.keywords, ["single-keyword"])
        XCTAssertEqual(metadata.fNumber ?? 0, 2.8, accuracy: 0.001)
        XCTAssertEqual(metadata.iso, 800)
        XCTAssertEqual(metadata.lens, "RF 50mm F1.2 L USM")
        XCTAssertEqual(metadata.rating, 5)
        XCTAssertEqual(metadata.location?.latitude ?? 0, 35.6586, accuracy: 0.001)
        XCTAssertEqual(metadata.location?.longitude ?? 0, 139.7454, accuracy: 0.001)
    }

    /// Lightroom's own map pin is decimal degrees a user may have placed by hand; it outranks
    /// whatever GPS the camera guessed at and wrote into the XMP.
    func testLightroomsLocationWinsOverTheFilesGPS() throws {
        let metadata = PhotoMetadata(payload: try payload("""
        {
          "location": {"latitude": 51.5, "longitude": -0.12},
          "xmp": {"exif": {"GPSLatitude": "35,39.516N", "GPSLongitude": "139,44.724E"}}
        }
        """))
        XCTAssertEqual(metadata.location, PhotoLocation(latitude: 51.5, longitude: -0.12))
    }

    func testKeywordsAreDeduplicatedAndTrimmed() throws {
        let metadata = PhotoMetadata(payload: try payload("""
        {"xmp": {"dc": {"subject": ["Tokyo", "  tokyo  ", "", "travel"]}}}
        """))
        XCTAssertEqual(metadata.keywords, ["Tokyo", "travel"])
    }

    /// Lightroom keys ratings by the Adobe user who set them, so the map has to be read rather
    /// than indexed, and the answer must not depend on dictionary order.
    func testTakesTheHighestRatingOutOfTheRatingsMap() throws {
        let metadata = PhotoMetadata(payload: try payload("""
        {"ratings": {"user-a": {"rating": 2}, "user-b": {"rating": 5}, "user-c": {"rating": 9}}}
        """))
        XCTAssertEqual(metadata.rating, 5)
    }

    func testOnlyFourStarsAndUpBecomeAFavorite() {
        XCTAssertEqual(PhotoMetadata.favoriteRatingThreshold, 4)
        XCTAssertFalse(PhotoMetadata(rating: 3).isFavorite)
        XCTAssertTrue(PhotoMetadata(rating: 4).isFavorite)
        XCTAssertTrue(PhotoMetadata(rating: 5).isFavorite)
        XCTAssertFalse(PhotoMetadata(rating: nil).isFavorite)
    }

    /// A stripped GPS block decodes to zeroes, which is a real place in the Atlantic. Treating it
    /// as a location would drop photos onto null island in the Photos map.
    func testRejectsImpossibleAndNullIslandCoordinates() {
        XCTAssertNil(PhotoLocation.validated(latitude: 0, longitude: 0))
        XCTAssertNil(PhotoLocation.validated(latitude: 91, longitude: 10))
        XCTAssertNil(PhotoLocation.validated(latitude: 10, longitude: -181))
        XCTAssertNil(PhotoLocation.validated(latitude: nil, longitude: 10))
        XCTAssertNil(PhotoLocation.validated(latitude: .nan, longitude: 10))
        XCTAssertNil(PhotoLocation.validated(latitude: 10, longitude: .infinity))
        // A photo on the equator or the prime meridian is a real photo; only both at once is not.
        XCTAssertEqual(PhotoLocation.validated(latitude: 0, longitude: 10)?.longitude, 10)
        XCTAssertEqual(PhotoLocation.validated(latitude: 10, longitude: 0)?.latitude, 10)
        // An unusable altitude drops out without taking the coordinates with it.
        XCTAssertNil(PhotoLocation.validated(latitude: 10, longitude: 10, altitude: .nan)?.altitude)
    }

    // MARK: - GPS coordinate formats

    func testParsesTheXMPCoordinateFormats() {
        XCTAssertEqual(GPSCoordinate.parse(.string("35,39.516N")) ?? 0, 35.6586, accuracy: 0.0001)
        XCTAssertEqual(GPSCoordinate.parse(.string("139,44,43.2W")) ?? 0, -139.7453, accuracy: 0.0001)
        XCTAssertEqual(GPSCoordinate.parse(.string("51,30S")) ?? 0, -51.5, accuracy: 0.0001)
        XCTAssertEqual(GPSCoordinate.parse(.string("-33.8688")) ?? 0, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(GPSCoordinate.parse(.number(48.8584)) ?? 0, 48.8584, accuracy: 0.0001)
        XCTAssertNil(GPSCoordinate.parse(.string("somewhere nice")))
        XCTAssertNil(GPSCoordinate.parse(.string("")))
        XCTAssertNil(GPSCoordinate.parse(nil))
    }

    // MARK: - Capture time

    /// The point of the whole exercise: a photo shot in Tokyo keeps its Tokyo instant when it is
    /// synced from a Mac in California, because the file says which zone the camera was set to.
    func testCaptureTimeUsesTheFilesTimeZoneOverTheMacs() {
        let california = TimeZone(secondsFromGMT: -7 * 3600)!
        let resolved = CaptureTime.resolve(rawCaptureDate: "2024-09-18T15:55:12",
                                           embeddedOffsetSeconds: 9 * 3600,
                                           localTimeZone: california)
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        XCTAssertEqual(resolved.date,
                       tokyo.date(from: DateComponents(year: 2024, month: 9, day: 18, hour: 15, minute: 55, second: 12)))
        XCTAssertEqual(resolved.offsetSeconds, 9 * 3600)

        // Without the tag there is nothing better to go on than the Mac's own zone, as before.
        let fallback = CaptureTime.resolve(rawCaptureDate: "2024-09-18T15:55:12",
                                           embeddedOffsetSeconds: nil, localTimeZone: california)
        XCTAssertEqual(fallback.date, AdobeDate.parse("2024-09-18T15:55:12", localTimeZone: california))
        XCTAssertNil(fallback.offsetSeconds)
    }

    /// A capture date that names its own zone is already an instant. The file's offset must not
    /// move it, and must not be reported as the zone it was read in.
    func testATimestampWithItsOwnZoneIgnoresTheFilesOffset() {
        let resolved = CaptureTime.resolve(rawCaptureDate: "2024-09-18T15:55:12Z",
                                           embeddedOffsetSeconds: 9 * 3600)
        XCTAssertEqual(resolved.date, AdobeDate.parse("2024-09-18T15:55:12Z"))
        XCTAssertNil(resolved.offsetSeconds)
    }

    func testAMissingCaptureDateResolvesToNothing() {
        XCTAssertNil(CaptureTime.resolve(rawCaptureDate: nil, embeddedOffsetSeconds: 3600).date)
        XCTAssertNil(CaptureTime.resolve(rawCaptureDate: "0000-00-00T00:00:00", embeddedOffsetSeconds: nil).date)
    }

    func testHasExplicitZone() {
        XCTAssertTrue(AdobeDate.hasExplicitZone("2024-09-18T21:07:30Z"))
        XCTAssertTrue(AdobeDate.hasExplicitZone("2024-09-18T21:07:30.325Z"))
        XCTAssertTrue(AdobeDate.hasExplicitZone("2024-09-18T21:07:30+02:00"))
        XCTAssertTrue(AdobeDate.hasExplicitZone("2024-09-18T21:07:30.384971-0700"))
        XCTAssertFalse(AdobeDate.hasExplicitZone("2024-09-18T21:07:30"))
        XCTAssertFalse(AdobeDate.hasExplicitZone("2024-09-18T21:07:30.325"))
        XCTAssertFalse(AdobeDate.hasExplicitZone(nil))
    }

    // MARK: - EXIF time formats

    /// EXIF writes the date with colons in place of dashes. Getting this wrong writes a tag every
    /// other program then misreads, which is exactly the failure this change exists to avoid.
    func testWritesTheEXIFTimestampFormat() {
        var tokyo = Calendar(identifier: .gregorian)
        let zone = TimeZone(secondsFromGMT: 9 * 3600)!
        tokyo.timeZone = zone
        let date = tokyo.date(from: DateComponents(year: 2024, month: 9, day: 8, hour: 5, minute: 5, second: 2))!
        XCTAssertEqual(EXIFTime.timestamp(date, in: zone), "2024:09:08 05:05:02")
        // The same instant read in another zone is a different wall-clock reading, as it should be.
        XCTAssertEqual(EXIFTime.timestamp(date, in: TimeZone(secondsFromGMT: 0)!), "2024:09:07 20:05:02")
    }

    func testWritesAndReadsTheOffsetTag() {
        XCTAssertEqual(EXIFTime.offsetTag(9 * 3600), "+09:00")
        XCTAssertEqual(EXIFTime.offsetTag(0), "+00:00")
        XCTAssertEqual(EXIFTime.offsetTag(-(3 * 3600 + 30 * 60)), "-03:30")
        XCTAssertEqual(EXIFTime.offsetTag(5 * 3600 + 45 * 60), "+05:45")

        for seconds in [9 * 3600, 0, -(3 * 3600 + 30 * 60), 5 * 3600 + 45 * 60, -11 * 3600] {
            XCTAssertEqual(EXIFTime.offsetSeconds(EXIFTime.offsetTag(seconds)), seconds)
        }
        XCTAssertEqual(EXIFTime.offsetSeconds("+0900"), 9 * 3600)
        XCTAssertEqual(EXIFTime.offsetSeconds("  -07:00 "), -7 * 3600)
    }

    func testRejectsOffsetTagsThatAreNotOffsets() {
        // EXIF leaves the tag as spaces when the camera did not know its zone.
        XCTAssertNil(EXIFTime.offsetSeconds("     "))
        XCTAssertNil(EXIFTime.offsetSeconds("+15:00"))
        XCTAssertNil(EXIFTime.offsetSeconds("+09:75"))
        XCTAssertNil(EXIFTime.offsetSeconds("09:00"))
        XCTAssertNil(EXIFTime.offsetSeconds("+9:00"))
        XCTAssertNil(EXIFTime.offsetSeconds(nil))
    }

    // MARK: - A file that says nothing

    func testAFileWithNoCameraTagsLooksStripped() {
        XCTAssertTrue(EmbeddedPhotoMetadata().looksStripped)
        XCTAssertFalse(EmbeddedPhotoMetadata(hasCaptureDate: true).looksStripped)
        XCTAssertFalse(EmbeddedPhotoMetadata(hasCameraInfo: true).looksStripped)
    }
}
