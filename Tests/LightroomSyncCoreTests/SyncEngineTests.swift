import XCTest
@testable import LightroomSyncCore

final class SyncEngineTests: XCTestCase {
    let share = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let album = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    var api: String { "https://lightroom.adobe.com/v2c/spaces/\(share)" }
    var assetsURL: String { "\(api)/albums/\(album)/assets?embed=asset&subtype=image%3Bvideo&limit=500" }

    private struct Harness {
        let transport: FakeTransport
        let importer: FakeImporter
        let sink: RecordingSink
        let ledger: Ledger
        let engine: SyncEngine
        let directory: URL
    }

    private func makeHarness(downloadsAllowed: Bool = true) throws -> Harness {
        let directory = try makeTemporaryDirectory()
        let transport = FakeTransport()
        transport.setJSON(api, #"{"id": "\#(share)", "type": "space", "createdOnClient": "AdobeNimbus-test", "payload": {"download": \#(downloadsAllowed), "private": false}}"#)
        transport.setJSON("\(api)/resources", #"{"base": "x", "resources": [{"id": "\#(album)", "type": "album", "subtype": "collection", "payload": {"name": "Test album"}, "links": {"self": {"href": "spaces/\#(share)/albums/\#(album)"}}}]}"#)
        let importer = FakeImporter()
        let sink = RecordingSink()
        let ledger = try Ledger(fileURL: directory.appendingPathComponent("ledger.json"))
        let engine = SyncEngine(client: LightroomGalleryClient(transport: transport), ledger: ledger, importer: importer,
                                downloadDirectory: directory.appendingPathComponent("downloads"), settleTime: 120, sink: sink)
        return Harness(transport: transport, importer: importer, sink: sink, ledger: ledger, engine: engine, directory: directory)
    }

    private func config(ignoreDelays: Bool = false, albumName: String? = "Lightroom") -> SyncConfiguration {
        SyncConfiguration(shareLink: "https://lightroom.adobe.com/shares/\(share)", preferredAlbumID: nil,
                          photosAlbumName: albumName, checkInterval: 15 * 60, ignoreDelays: ignoreDelays)
    }

    private func setDownload(_ harness: Harness, assetID: String, width: Int, height: Int) {
        harness.transport.set("https://dl.lightroom.adobe.com/spaces/\(share)/assets/\(assetID)",
                              headers: ["content-type": "image/jpeg", "content-disposition": "attachment; filename=\"\(assetID).jpg\""],
                              body: fakeJPEG(width: width, height: height))
    }

    func testSyncsEligiblePhotosOnceAndLeavesRecentOnesWaiting() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let now = Date()
        let old = now.addingTimeInterval(-3600)
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "old1", fileName: "old.jpg", sha: "sha-old", added: old, edited: old),
            assetEntry(id: "new1", fileName: "new.jpg", sha: "sha-new", added: now.addingTimeInterval(-60)),
        ]))
        setDownload(harness, assetID: "old1", width: 4000, height: 3000)

        let report = try await harness.engine.run(config(), now: now)
        XCTAssertEqual(report.albumName, "Test album")
        XCTAssertEqual(report.photosInAlbum, 2)
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.pending, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(harness.importer.requests.count, 1)
        XCTAssertEqual(harness.importer.requests[0].albumName, "Lightroom")
        XCTAssertEqual(harness.importer.requests[0].originalFileName, "old1.jpg")
        XCTAssertNotNil(harness.importer.requests[0].captureDate)
        XCTAssertTrue(harness.ledger.contains(assetID: "old1"))
        XCTAssertEqual(harness.ledger.state.entries["old1"]?.photosLocalIdentifier, "local-1")
        XCTAssertEqual(harness.ledger.state.entries["old1"]?.pixelWidth, 4000)
        XCTAssertNotNil(harness.ledger.state.firstSeen["new1"])

        // A later edit of an already synced photo must not trigger a re-sync.
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "old1", fileName: "old.jpg", sha: "sha-old", added: old, edited: now.addingTimeInterval(-10)),
            assetEntry(id: "new1", fileName: "new.jpg", sha: "sha-new", added: now.addingTimeInterval(-60)),
        ]))
        let second = try await harness.engine.run(config(), now: now.addingTimeInterval(120))
        XCTAssertEqual(second.alreadySynced, 1)
        XCTAssertEqual(second.synced, 0)
        XCTAssertEqual(second.pending, 1)
        XCTAssertEqual(harness.importer.requests.count, 1)

        // "Sync now" ignores the delay.
        setDownload(harness, assetID: "new1", width: 4000, height: 3000)
        let third = try await harness.engine.run(config(ignoreDelays: true), now: now.addingTimeInterval(130))
        XCTAssertEqual(third.synced, 1)
        XCTAssertEqual(third.alreadySynced, 1)
        XCTAssertEqual(harness.ledger.syncedCount, 2)
        XCTAssertTrue(harness.ledger.state.firstSeen.isEmpty)

        // Temporary downloads are cleaned up.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: harness.directory.appendingPathComponent("downloads").path)) ?? []
        XCTAssertEqual(leftovers, [])
    }

    func testDuplicateOriginalIsNotImportedTwice() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let old = Date().addingTimeInterval(-7200)
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "p1", fileName: "a.jpg", sha: "same", added: old, edited: old),
            assetEntry(id: "p2", fileName: "a-copy.jpg", sha: "same", added: old, edited: old),
        ]))
        setDownload(harness, assetID: "p1", width: 4000, height: 3000)
        setDownload(harness, assetID: "p2", width: 4000, height: 3000)
        let report = try await harness.engine.run(config())
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.duplicates, 1)
        XCTAssertEqual(harness.importer.requests.count, 1)
        XCTAssertEqual(harness.ledger.state.entries["p2"]?.photosLocalIdentifier, "local-1")
    }

    func testDownloadsDisabledAbortsThePass() async throws {
        let harness = try makeHarness(downloadsAllowed: false)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        do {
            _ = try await harness.engine.run(config())
            XCTFail("expected an error")
        } catch let error as LightroomError {
            XCTAssertEqual(error, .downloadsDisabled)
        }
        XCTAssertTrue(harness.transport.requests.allSatisfy { !$0.absoluteString.contains("dl.lightroom") })
    }

    func testFailuresAreCountedAndDoNotStopOtherPhotos() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let old = Date().addingTimeInterval(-7200)
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "fails", fileName: "fails.jpg", added: old, edited: old),
            assetEntry(id: "missing", fileName: "missing.jpg", added: old, edited: old),
            assetEntry(id: "small", fileName: "small.jpg", added: old, edited: old, cropped: (6000, 4000)),
            assetEntry(id: "video", fileName: "clip.mp4", added: old, edited: old, subtype: "video"),
        ]))
        setDownload(harness, assetID: "fails", width: 4000, height: 3000)
        setDownload(harness, assetID: "small", width: 2048, height: 1365)
        harness.importer.failNext = true

        let report = try await harness.engine.run(config(albumName: nil))
        XCTAssertEqual(report.photosInAlbum, 3, "videos are ignored")
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.downgraded, 1)
        XCTAssertEqual(harness.ledger.state.entries["small"]?.downgraded, true)
        XCTAssertFalse(harness.ledger.contains(assetID: "fails"), "a failed import is retried next time")
        XCTAssertNil(harness.importer.requests.first?.albumName)
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("[warning]") && $0.contains("small.jpg") })
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("[error]") && $0.contains("missing.jpg") })
    }

    func testInvalidLinkAndAlbumSelection() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        do {
            _ = try await harness.engine.run(SyncConfiguration(shareLink: "nope", checkInterval: 60))
            XCTFail("expected an error")
        } catch let error as SyncEngineError {
            if case .invalidShareLink = error {} else { XCTFail("unexpected \(error)") }
        }
        do {
            _ = try await harness.engine.run(SyncConfiguration(shareLink: "https://lightroom.adobe.com/shares/\(share)",
                                                                preferredAlbumID: "cccccccccccccccccccccccccccccccc", checkInterval: 60))
            XCTFail("expected an error")
        } catch let error as SyncEngineError {
            XCTAssertEqual(error, .albumNotFound("cccccccccccccccccccccccccccccccc"))
        }
    }
}
