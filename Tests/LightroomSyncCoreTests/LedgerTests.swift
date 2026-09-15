import XCTest
@testable import LightroomSyncCore

final class LedgerTests: XCTestCase {
    func testRoundTripAndLookups() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/ledger.json")

        let ledger = try Ledger(fileURL: url)
        XCTAssertEqual(ledger.syncedCount, 0)
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(try ledger.noteSeen(assetID: "p1", at: seen), seen)
        XCTAssertEqual(try ledger.noteSeen(assetID: "p1", at: seen.addingTimeInterval(99)), seen, "first-seen is sticky")

        let entry = LedgerEntry(assetID: "p1", shareID: "s", albumID: "a", fileName: "x.jpg", originalSHA256: "sha1",
                                photosLocalIdentifier: "local-1", syncedAt: seen, captureDate: nil,
                                pixelWidth: 10, pixelHeight: 20, downgraded: false)
        try ledger.record(entry)

        let reloaded = try Ledger(fileURL: url)
        XCTAssertTrue(reloaded.contains(assetID: "p1"))
        XCTAssertFalse(reloaded.contains(assetID: "p2"))
        XCTAssertEqual(reloaded.entry(withOriginalSHA256: "sha1"), entry)
        XCTAssertNil(reloaded.state.firstSeen["p1"], "recording clears the pending marker")
        XCTAssertEqual(reloaded.syncedCount, 1)
    }

    func testLedgerWrittenBeforeAlbumsWereTrackedStillLoads() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        // Exactly the shape the first release wrote: no photosAlbumName anywhere.
        let json = """
        {
          "entries": {
            "asset-1": {
              "albumID": "b", "assetID": "asset-1", "downgraded": false, "fileName": "a.jpg",
              "photosLocalIdentifier": "local-1", "shareID": "s", "syncedAt": "2026-09-14T15:00:00Z"
            }
          },
          "firstSeen": {}
        }
        """
        try Data(json.utf8).write(to: url)

        let ledger = try Ledger(fileURL: url)
        XCTAssertTrue(ledger.contains(assetID: "asset-1"))
        XCTAssertNil(ledger.state.entries["asset-1"]?.photosAlbumName, "an unknown album, not a crash")

        try ledger.markFiled(["asset-1", "unknown"], inAlbum: "Lightroom")
        XCTAssertEqual(try Ledger(fileURL: url).state.entries["asset-1"]?.photosAlbumName, "Lightroom")
    }

    func testCorruptLedgerIsReportedNotSilentlyReplaced() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.json")
        try Data("{ this is not json".utf8).write(to: url)
        XCTAssertThrowsError(try Ledger(fileURL: url))
    }
}
