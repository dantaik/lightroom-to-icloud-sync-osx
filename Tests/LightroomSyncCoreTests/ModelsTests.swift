import XCTest
@testable import LightroomSyncCore

final class ModelsTests: XCTestCase {
    func testDecodesSpace() throws {
        let space = try AdobeJSON.decode(SpaceResponse.self, from: Fixtures.data("space"))
        XCTAssertEqual(space.id, "680b19438c8c46ccbac6b0ec71cc9c96")
        XCTAssertEqual(space.payload?.download, true)
        XCTAssertEqual(space.payload?.isPrivate, false)
        XCTAssertEqual(space.createdOnClient, "AdobeNimbus-7.5.20240801_2320_5b173a1-OSX")
    }

    func testDecodesResources() throws {
        let resources = try AdobeJSON.decode(ResourcesResponse.self, from: Fixtures.data("space_resources"))
        XCTAssertEqual(resources.resources.count, 1)
        let album = resources.resources[0]
        XCTAssertEqual(album.type, "album")
        XCTAssertEqual(album.payload?.name, "September 14th 2025 Collection")
        XCTAssertNotNil(album.links?["/rels/space_album_images_videos"])
    }

    func testDecodesAlbumAssetsPageAndNormalizesPhotos() throws {
        let page = try AdobeJSON.decode(AlbumAssetsPage.self, from: Fixtures.data("album_assets_page"))
        XCTAssertEqual(page.resources.count, 2)
        XCTAssertEqual(page.links?["next"]?.hasPrefix("albums/63e4b83141a34bd58e2865d07b3c089c/assets?"), true)

        let photos = page.resources.compactMap(LightroomPhoto.init(entry:))
        XCTAssertEqual(photos.count, 2)
        let first = photos[0]
        XCTAssertEqual(first.assetID, "5dbd9a08573944d29afba1eb55658adc")
        XCTAssertEqual(first.fileName, "Pitrat_Megan.jpg")
        XCTAssertEqual(first.subtype, "image")
        XCTAssertTrue(first.isImage)
        XCTAssertEqual(first.originalWidth, 3052)
        XCTAssertEqual(first.originalHeight, 4069)
        XCTAssertEqual(first.croppedWidth, 3052)
        XCTAssertEqual(first.expectedLongEdge, 4069)
        XCTAssertTrue(first.hasEdits)
        XCTAssertEqual(first.originalSHA256?.count, 64)
        XCTAssertEqual(first.addedToAlbumAt, AdobeDate.parse("2024-09-18T21:07:30.325Z"))
        XCTAssertEqual(first.lastEditedAt, AdobeDate.parse("2024-09-18T21:07:30.325Z"),
                       "the generic asset.updated (2026) must not count as an edit")
        XCTAssertNotNil(first.captureDate)
    }

    func testExpectedPhotosFileNameIsTheOriginalNameAsJPEG() {
        func photo(named fileName: String?) -> LightroomPhoto {
            LightroomPhoto(assetID: "a", subtype: "image", fileName: fileName, originalSHA256: nil,
                           originalWidth: nil, originalHeight: nil, croppedWidth: nil, croppedHeight: nil,
                           captureDate: nil, addedToAlbumAt: nil, lastEditedAt: nil, hasEdits: false)
        }
        XCTAssertEqual(photo(named: "DSC_3920.NEF").expectedPhotosFileName, "DSC_3920.jpg")
        XCTAssertEqual(photo(named: "L1000133.DNG").expectedPhotosFileName, "L1000133.jpg")
        XCTAssertEqual(photo(named: "I - Jan.JPG").expectedPhotosFileName, "I - Jan.jpg")
        XCTAssertEqual(photo(named: "IMG_6804.PNG").expectedPhotosFileName, "IMG_6804.jpg")
        XCTAssertEqual(photo(named: "holiday.2024.raw.dng").expectedPhotosFileName, "holiday.2024.raw.jpg")
        XCTAssertEqual(photo(named: "no-extension").expectedPhotosFileName, "no-extension.jpg")
        XCTAssertEqual(photo(named: ".hidden").expectedPhotosFileName, ".hidden.jpg")
        XCTAssertNil(photo(named: nil).expectedPhotosFileName)
        XCTAssertNil(photo(named: "").expectedPhotosFileName)
    }

    func testLinkMapIgnoresNonLinkValues() throws {
        let json = #"{"self": {"href": "a"}, "/rels/comments": {"href": "c", "count": 0}, "weird": 5, "other": {"nope": 1}}"#
        let links = try JSONDecoder().decode(LinkMap.self, from: Data(json.utf8))
        XCTAssertEqual(links.hrefs, ["self": "a", "/rels/comments": "c"])
    }
}
