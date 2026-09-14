import XCTest
@testable import LightroomSyncCore

final class ShareLinkTests: XCTestCase {
    let id = "6e0423ddf2a140adb6eaf29b27a72174"

    func testParsesShareURL() throws {
        let link = try ShareLink.parse("https://lightroom.adobe.com/shares/\(id)")
        XCTAssertEqual(link.kind, .share(shareID: id, albumID: nil))
    }

    func testParsesShareURLWithAlbumDeepLink() throws {
        let album = "41bfa499465e1cf5afba77eff611e66d"
        let link = try ShareLink.parse("https://lightroom.adobe.com/shares/\(id)/albums/\(album)/assets/bf2d428d577448d0a62bd22a51be9c05")
        XCTAssertEqual(link.kind, .share(shareID: id, albumID: album))
    }

    func testAcceptsBareIDAndMissingScheme() throws {
        XCTAssertEqual(try ShareLink.parse("  \(id.uppercased()) ").kind, .share(shareID: id, albumID: nil))
        XCTAssertEqual(try ShareLink.parse("lightroom.adobe.com/shares/\(id)?x=1").kind, .share(shareID: id, albumID: nil))
    }

    func testShortLink() throws {
        let link = try ShareLink.parse("https://adobe.ly/3tI5eF4")
        XCTAssertEqual(link.kind, .shortLink(URL(string: "https://adobe.ly/3tI5eF4")!))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try ShareLink.parse(""))
        XCTAssertThrowsError(try ShareLink.parse("https://example.com/shares/\(id)"))
        XCTAssertThrowsError(try ShareLink.parse("https://lightroom.adobe.com/shares/not-an-id"))
        XCTAssertThrowsError(try ShareLink.parse("https://adobe.ly/"))
    }
}
