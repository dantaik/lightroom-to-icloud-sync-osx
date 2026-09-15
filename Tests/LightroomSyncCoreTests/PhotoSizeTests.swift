import XCTest
@testable import LightroomSyncCore

final class PhotoSizeTests: XCTestCase {
    func testTheLadderRunsFromAProDisplayXDRDownToARenditionLightroomHolds() {
        XCTAssertEqual(PhotoSize.allCases, [.large, .medium, .small, .original])
        XCTAssertEqual(PhotoSize.default, .large)
        XCTAssertEqual(PhotoSize.large.maxLongEdge, 6016, "the width of a Pro Display XDR")
        XCTAssertEqual(PhotoSize.medium.maxLongEdge, 3840, "4K")
        XCTAssertEqual(PhotoSize.small.maxLongEdge, 2048, "what Lightroom already renders")
        XCTAssertNil(PhotoSize.original.maxLongEdge)
    }

    func testOnlyTheSmallSizeHasARenditionToAskFor() {
        XCTAssertEqual(PhotoSize.small.renditionType, "2048")
        XCTAssertNil(PhotoSize.large.renditionType)
        XCTAssertNil(PhotoSize.medium.renditionType)
        XCTAssertNil(PhotoSize.original.renditionType, "the download host is the only source of a full-size render")
    }

    func testTheIntendedSizeIsTheEditCappedByTheSetting() {
        // A 60 MP edit is capped; a photo smaller than the cap is never stretched up to it.
        XCTAssertEqual(PhotoSize.large.intendedLongEdge(editedLongEdge: 9528), 6016)
        XCTAssertEqual(PhotoSize.large.intendedLongEdge(editedLongEdge: 4000), 4000)
        XCTAssertEqual(PhotoSize.small.intendedLongEdge(editedLongEdge: 9528), 2048)
        XCTAssertEqual(PhotoSize.original.intendedLongEdge(editedLongEdge: 9528), 9528)
        XCTAssertNil(PhotoSize.large.intendedLongEdge(editedLongEdge: nil),
                     "nothing is expected of a photo Lightroom gives no size for")
    }

    func testEverySizeReadsAsSomethingInTheUI() {
        XCTAssertEqual(PhotoSize.large.menuLabel, "Large — 6016 px")
        XCTAssertEqual(PhotoSize.original.menuLabel, "Original — full size")
        XCTAssertEqual(PhotoSize.medium.shortDescription, "3840 px")
        XCTAssertEqual(PhotoSize.original.shortDescription, "full size")
        for size in PhotoSize.allCases {
            XCTAssertFalse(size.title.isEmpty)
            XCTAssertFalse(size.summary.isEmpty, "the picker explains what each size means")
            XCTAssertEqual(PhotoSize(rawValue: size.rawValue), size, "the raw value is what settings store")
        }
    }
}
