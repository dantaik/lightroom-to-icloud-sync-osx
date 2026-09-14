import XCTest
@testable import LightroomSyncCore

final class JPEGInfoTests: XCTestCase {
    func testReadsDimensionsFromSOF() {
        XCTAssertEqual(JPEGInfo.pixelSize(of: fakeJPEG(width: 6016, height: 4016)), JPEGInfo.PixelSize(width: 6016, height: 4016))
        XCTAssertEqual(JPEGInfo.pixelSize(of: fakeJPEG(width: 1, height: 65535))?.longEdge, 65535)
    }

    func testRejectsNonJPEGAndTruncatedData() {
        XCTAssertNil(JPEGInfo.pixelSize(of: Data("not a jpeg".utf8)))
        XCTAssertNil(JPEGInfo.pixelSize(of: Data([0xFF, 0xD8, 0xFF])))
        XCTAssertNil(JPEGInfo.pixelSize(of: fakeJPEG(width: 10, height: 10).prefix(12)))
        XCTAssertNil(JPEGInfo.pixelSize(of: Data([0xFF, 0xD8, 0xFF, 0xD9])))
    }
}
