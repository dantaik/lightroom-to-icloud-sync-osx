import XCTest
@testable import LightroomSyncCore

/// The rules that decide when Lightroom's own copy on this Mac may stand in for a download.
///
/// All of them exist to stop the local library quietly changing what lands in Photos: a photo
/// that is smaller than the settings ask for, or that predates the last edit, is worse than a
/// slow download, and the ledger records it as done either way.
final class LocalPhotoSourceTests: XCTestCase {
    private let share = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let album = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private var api: String { "https://lightroom.adobe.com/v2c/spaces/\(share)" }
    private var assetsURL: String { "\(api)/albums/\(album)/assets?embed=asset&subtype=image%3Bvideo&limit=500" }
    private var downloadURL: String { "https://dl.lightroom.adobe.com/spaces/\(share)/assets/p1" }

    private struct Harness {
        let transport: FakeTransport
        let local: FakeLocalSource
        let importer: FakeImporter
        let sink: RecordingSink
        let ledger: Ledger
        let engine: SyncEngine
        let directory: URL
    }

    /// One photo, edited two hours ago, with a full-size download available.
    private func makeHarness(editedAt: Date) throws -> Harness {
        let directory = try makeTemporaryDirectory()
        let transport = FakeTransport()
        transport.setJSON(api, #"{"id": "\#(share)", "type": "space", "createdOnClient": "t", "payload": {"download": true}}"#)
        transport.setJSON("\(api)/resources", #"{"base": "x", "resources": [{"id": "\#(album)", "type": "album", "payload": {"name": "Test album"}}]}"#)
        transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "p1", fileName: "L1002205.DNG", added: editedAt, edited: editedAt, cropped: (9528, 6328)),
        ]))
        transport.set(downloadURL,
                      headers: ["content-type": "image/jpeg", "content-disposition": "attachment; filename=\"L1002205.DNG\""],
                      body: fakeJPEG(width: 9528, height: 6328, picture: "p1"))
        let importer = FakeImporter()
        let photoLibrary = FakePhotoLibrary()
        importer.library = photoLibrary
        let sink = RecordingSink()
        let local = FakeLocalSource()
        let ledger = try Ledger(fileURL: directory.appendingPathComponent("ledger.json"))
        let engine = SyncEngine(client: LightroomGalleryClient(transport: transport), ledger: ledger,
                                importer: importer, photoLibrary: photoLibrary, resizer: FakeResizer(),
                                metadataWriter: FakeMetadataWriter(), localSource: local,
                                downloadDirectory: directory.appendingPathComponent("downloads"),
                                settleTime: 120, sink: sink)
        return Harness(transport: transport, local: local, importer: importer, sink: sink,
                       ledger: ledger, engine: engine, directory: directory)
    }

    private func config(size: PhotoSize) -> SyncConfiguration {
        SyncConfiguration(shareLink: "https://lightroom.adobe.com/shares/\(share)",
                          photosAlbumName: nil, checkInterval: 15 * 60, photoSize: size)
    }

    private func downloadWasMade(_ harness: Harness) -> Bool {
        harness.transport.requests.contains { $0.absoluteString == downloadURL }
    }

    func testAMatchingLocalRenditionIsUsedAndNothingIsDownloaded() async throws {
        let edited = Date().addingTimeInterval(-7200)
        let harness = try makeHarness(editedAt: edited)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.local.held["p1"] = .init(longEdge: 6016, renderedAt: edited.addingTimeInterval(60),
                                         source: "preview, 6016 px")

        let report = try await harness.engine.run(config(size: .large))
        XCTAssertEqual(report.synced, 1)
        XCTAssertFalse(downloadWasMade(harness), "the local copy covered the size asked for")
        XCTAssertEqual(harness.local.requests.map(\.minimumLongEdge), [6016])
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("taken from Lightroom's library on this Mac") })
    }

    func testALocalRenditionSmallerThanTheChosenSizeIsNotUsed() async throws {
        let edited = Date().addingTimeInterval(-7200)
        let harness = try makeHarness(editedAt: edited)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        // What Lightroom's previews really are next to a 6016 px setting.
        harness.local.held["p1"] = .init(longEdge: 2560, renderedAt: edited.addingTimeInterval(60))

        let report = try await harness.engine.run(config(size: .large))
        XCTAssertEqual(report.synced, 1)
        XCTAssertTrue(downloadWasMade(harness), "a short preview must not stand in for the full size")
    }

    func testALocalRenditionOlderThanTheLastEditIsNotUsed() async throws {
        let edited = Date().addingTimeInterval(-7200)
        let harness = try makeHarness(editedAt: edited)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        // Lightroom on this Mac has not caught up with an edit made elsewhere.
        harness.local.held["p1"] = .init(longEdge: 6016, renderedAt: edited.addingTimeInterval(-3600))

        let report = try await harness.engine.run(config(size: .large))
        XCTAssertEqual(report.synced, 1)
        XCTAssertTrue(downloadWasMade(harness))
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("predates the last edit") })
    }

    func testOriginalSizeNeverUsesTheLocalLibrary() async throws {
        let edited = Date().addingTimeInterval(-7200)
        let harness = try makeHarness(editedAt: edited)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.local.held["p1"] = .init(longEdge: 99_999, renderedAt: Date())

        let report = try await harness.engine.run(config(size: .original))
        XCTAssertEqual(report.synced, 1)
        XCTAssertTrue(downloadWasMade(harness), "“Original” means whatever Lightroom renders, which no cached file can promise to be")
        XCTAssertTrue(harness.local.requests.isEmpty, "the library should not even be asked")
    }

    func testALocalSourceThatFailsDoesNotFailThePass() async throws {
        let edited = Date().addingTimeInterval(-7200)
        let harness = try makeHarness(editedAt: edited)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        harness.local.error = NSError(domain: "Lightroom", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "catalog is locked"])

        let report = try await harness.engine.run(config(size: .large))
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(downloadWasMade(harness))
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("could not read Lightroom's local copy") })
    }

    func testWithNoLocalLibraryEveryPhotoIsDownloadedAsBefore() async throws {
        let edited = Date().addingTimeInterval(-7200)
        let harness = try makeHarness(editedAt: edited)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        // `held` left empty: the library has nothing for this photo.

        let report = try await harness.engine.run(config(size: .large))
        XCTAssertEqual(report.synced, 1)
        XCTAssertTrue(downloadWasMade(harness))
    }
}
