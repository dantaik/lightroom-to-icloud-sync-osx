import XCTest
@testable import LightroomSyncCore

final class PhotoContentHashTests: XCTestCase {
    /// A plausible EXIF packet and a comment: the kinds of segment two copies of one photograph
    /// differ in, and the whole reason the hash is taken the way it is.
    private let exif: (marker: UInt8, payload: [UInt8]) = (0xE1, Array("Exif\0\0MM\0*Nikon D850".utf8))
    private let comment: (marker: UInt8, payload: [UInt8]) = (0xFE, Array("exported by Lightroom".utf8))

    func testTheSamePictureDescribedDifferentlyHashesTheSame() throws {
        let bare = fakeJPEG(width: 4000, height: 3000, picture: "one and the same")
        let described = fakeJPEG(width: 4000, height: 3000, picture: "one and the same",
                                 metadata: [exif, comment])
        XCTAssertNotEqual(bare, described, "the files genuinely differ")

        let hash = try XCTUnwrap(PhotoContentHash.sha256(of: bare))
        XCTAssertEqual(PhotoContentHash.sha256(of: described), hash,
                       "what the file says about the photo is not part of the photo")
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testADifferentPictureHashesDifferently() throws {
        let one = try XCTUnwrap(PhotoContentHash.sha256(of: fakeJPEG(width: 4000, height: 3000, picture: "a")))
        let other = try XCTUnwrap(PhotoContentHash.sha256(of: fakeJPEG(width: 4000, height: 3000, picture: "b")))
        XCTAssertNotEqual(one, other)
    }

    /// The same pixels at two sizes are two different files to hash, which is why the hash is
    /// taken on the download as served and never stands in for the photo across a size change.
    func testTheSamePictureAtAnotherSizeHashesDifferently() throws {
        let large = try XCTUnwrap(PhotoContentHash.sha256(of: fakeJPEG(width: 4000, height: 3000, picture: "a")))
        let small = try XCTUnwrap(PhotoContentHash.sha256(of: fakeJPEG(width: 2048, height: 1536, picture: "a")))
        XCTAssertNotEqual(large, small)
    }

    func testFileAndBytesAgree() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("photo.jpg")
        let data = fakeJPEG(width: 100, height: 50, picture: "on disk")
        try data.write(to: url)
        XCTAssertEqual(PhotoContentHash.sha256(ofFileAt: url), PhotoContentHash.sha256(of: data))
    }

    /// A doubtful digest would be worse than none: the photo would be taken for another one. Every
    /// one of these falls back on the identities that need no hash.
    func testWhatCannotBeReadHasNoHash() {
        XCTAssertNil(PhotoContentHash.sha256(of: Data("not a jpeg".utf8)))
        XCTAssertNil(PhotoContentHash.sha256(of: Data()))
        XCTAssertNil(PhotoContentHash.sha256(of: Data([0xFF, 0xD8, 0xFF])))
        XCTAssertNil(PhotoContentHash.sha256(of: fakeJPEG(width: 10, height: 10, picture: "x").prefix(20)),
                     "a truncated file stops inside a segment")
        XCTAssertNil(PhotoContentHash.sha256(of: Data([0xFF, 0xD8, 0xFF, 0xD9])),
                     "a file with no scan carries no picture to identify")
        XCTAssertNil(PhotoContentHash.sha256(ofFileAt: URL(fileURLWithPath: "/no/such/photo.jpg")))
    }
}
