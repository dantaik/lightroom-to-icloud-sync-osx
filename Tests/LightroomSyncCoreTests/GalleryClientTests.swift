import XCTest
@testable import LightroomSyncCore

final class GalleryClientTests: XCTestCase {
    let share = "680b19438c8c46ccbac6b0ec71cc9c96"
    let album = "63e4b83141a34bd58e2865d07b3c089c"

    func testResolvesShortLinkThroughRedirect() async throws {
        let transport = FakeTransport()
        transport.set("https://adobe.ly/abc", finalURL: URL(string: "https://lightroom.adobe.com/shares/\(share)")!)
        let client = LightroomGalleryClient(transport: transport)
        let resolved = try await client.resolve(try AlbumShareLink.parse("https://adobe.ly/abc"))
        XCTAssertEqual(resolved.shareID, share)
        XCTAssertNil(resolved.albumID)
        XCTAssertEqual(transport.lastHeaders["User-Agent"], LightroomGalleryClient.defaultUserAgent)
    }

    func testFetchShareCombinesSpaceAndResources() async throws {
        let transport = FakeTransport()
        transport.set("https://lightroom.adobe.com/v2c/spaces/\(share)", body: try Fixtures.data("space"))
        transport.set("https://lightroom.adobe.com/v2c/spaces/\(share)/resources", body: try Fixtures.data("space_resources"))
        let client = LightroomGalleryClient(transport: transport)
        let info = try await client.fetchShare(shareID: share)
        XCTAssertTrue(info.downloadsAllowed)
        XCTAssertEqual(info.albums.map(\.name), ["September 14th 2025 Collection"])
        XCTAssertEqual(info.albums[0].id, "085ca26978b34951bcbe917ba6d79297")
    }

    func testListPhotosFollowsNextLinks() async throws {
        let transport = FakeTransport()
        let base = "https://lightroom.adobe.com/v2c/spaces/\(share)/"
        let now = Date()
        transport.setJSON(base + "albums/\(album)/assets?embed=asset&subtype=image%3Bvideo&limit=500",
                          assetsPageJSON(entries: [assetEntry(id: "a1", fileName: "one.jpg", added: now)],
                                         next: "albums/\(album)/assets?limit=500&captured_after=x&embed=asset"))
        transport.setJSON(base + "albums/\(album)/assets?limit=500&captured_after=x&embed=asset",
                          assetsPageJSON(entries: [assetEntry(id: "a2", fileName: "two.jpg", added: now, subtype: "video")]))
        let client = LightroomGalleryClient(transport: transport)
        let photos = try await client.listPhotos(shareID: share, albumID: album)
        XCTAssertEqual(photos.map(\.assetID), ["a1", "a2"])
        XCTAssertEqual(photos.map(\.isImage), [true, false])
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testDownloadWritesFileAndReadsFileName() async throws {
        let transport = FakeTransport()
        let jpeg = fakeJPEG(width: 3052, height: 4069)
        transport.set("https://dl.lightroom.adobe.com/spaces/\(share)/assets/a1",
                      headers: ["Content-Type": "image/jpeg", "Content-Disposition": "attachment; filename*=utf-8''Pitrat%20Megan.jpg"],
                      body: jpeg)
        let client = LightroomGalleryClient(transport: transport)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloaded = try await client.downloadFullSize(shareID: share, assetID: "a1", to: directory)
        XCTAssertEqual(downloaded.fileName, "Pitrat Megan.jpg")
        XCTAssertEqual(downloaded.fileURL.lastPathComponent, "a1.jpg")
        XCTAssertEqual(downloaded.byteCount, jpeg.count)
        XCTAssertEqual(JPEGInfo.pixelSize(ofFileAt: downloaded.fileURL), JPEGInfo.PixelSize(width: 3052, height: 4069))
    }

    func testDownloadsARenditionRelativeToTheSpace() async throws {
        let transport = FakeTransport()
        let href = "assets/a1/revisions/r1/renditions/abc"
        transport.set("https://lightroom.adobe.com/v2c/spaces/\(share)/\(href)",
                      headers: ["Content-Type": "image/jpeg"], body: fakeJPEG(width: 2048, height: 1365))
        let client = LightroomGalleryClient(transport: transport)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloaded = try await client.downloadRendition(shareID: share, assetID: "a1", href: href, to: directory)
        XCTAssertEqual(downloaded.fileURL.lastPathComponent, "a1.jpg")
        XCTAssertNil(downloaded.fileName, "a rendition carries no content-disposition")
        XCTAssertEqual(JPEGInfo.pixelSize(ofFileAt: downloaded.fileURL), JPEGInfo.PixelSize(width: 2048, height: 1365))
    }

    func testAMissingRenditionIsAnOrdinaryHTTPFailure() async throws {
        let transport = FakeTransport()
        let client = LightroomGalleryClient(transport: transport)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await client.downloadRendition(shareID: share, assetID: "a1", href: "assets/a1/renditions/gone", to: directory)
            XCTFail("expected an error")
        } catch let error as LightroomError {
            // Never downloadsDisabled: a rendition is viewable in the gallery whatever the share
            // allows, so a failure here must not abort the whole pass.
            guard case .httpStatus(404, _) = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testDownloadForbiddenMeansDownloadsDisabled() async throws {
        let transport = FakeTransport()
        transport.set("https://dl.lightroom.adobe.com/spaces/\(share)/assets/a1", status: 403, body: Data("forbidden".utf8))
        let client = LightroomGalleryClient(transport: transport)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await client.downloadFullSize(shareID: share, assetID: "a1", to: directory)
            XCTFail("expected an error")
        } catch let error as LightroomError {
            XCTAssertEqual(error, .downloadsDisabled)
        }
    }

    func testDownloadRejectsNonImage() async throws {
        let transport = FakeTransport()
        transport.set("https://dl.lightroom.adobe.com/spaces/\(share)/assets/a1", headers: ["Content-Type": "text/html"], body: Data("<html>".utf8))
        let client = LightroomGalleryClient(transport: transport)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await client.downloadFullSize(shareID: share, assetID: "a1", to: directory)
            XCTFail("expected an error")
        } catch let error as LightroomError {
            XCTAssertEqual(error, .unexpectedContentType("text/html"))
        }
    }

    func testContentDispositionParsing() {
        XCTAssertEqual(LightroomGalleryClient.fileName(fromContentDisposition: "attachment; filename*=utf-8''I%20-%20Jan.jpg"), "I - Jan.jpg")
        XCTAssertEqual(LightroomGalleryClient.fileName(fromContentDisposition: "attachment; filename=\"DSC_3920.jpg\""), "DSC_3920.jpg")
        XCTAssertEqual(LightroomGalleryClient.fileName(fromContentDisposition: "inline"), nil)
        XCTAssertEqual(LightroomGalleryClient.fileName(fromContentDisposition: nil), nil)
        XCTAssertEqual(LightroomGalleryClient.fileExtension(for: "image/png"), "png")
        XCTAssertEqual(LightroomGalleryClient.fileExtension(for: "image/jpeg; charset=binary"), "jpg")
    }
}
