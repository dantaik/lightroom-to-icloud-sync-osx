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
        let photoLibrary: FakePhotoLibrary
        let resizer: FakeResizer
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
        let photoLibrary = FakePhotoLibrary()
        importer.library = photoLibrary
        let sink = RecordingSink()
        let resizer = FakeResizer()
        let ledger = try Ledger(fileURL: directory.appendingPathComponent("ledger.json"))
        let engine = SyncEngine(client: LightroomGalleryClient(transport: transport), ledger: ledger, importer: importer,
                                photoLibrary: photoLibrary, resizer: resizer,
                                downloadDirectory: directory.appendingPathComponent("downloads"), settleTime: 120, sink: sink)
        return Harness(transport: transport, importer: importer, photoLibrary: photoLibrary, resizer: resizer,
                       sink: sink, ledger: ledger, engine: engine, directory: directory)
    }

    private func config(ignoreDelays: Bool = false, albumName: String? = "Lightroom",
                        size: PhotoSize = .default) -> SyncConfiguration {
        SyncConfiguration(shareLink: "https://lightroom.adobe.com/shares/\(share)", preferredAlbumID: nil,
                          photosAlbumName: albumName, checkInterval: 15 * 60, photoSize: size, ignoreDelays: ignoreDelays)
    }

    private func setDownload(_ harness: Harness, assetID: String, width: Int, height: Int) {
        harness.transport.set("https://dl.lightroom.adobe.com/spaces/\(share)/assets/\(assetID)",
                              headers: ["content-type": "image/jpeg", "content-disposition": "attachment; filename=\"\(assetID).jpg\""],
                              body: fakeJPEG(width: width, height: height))
    }

    /// The rendition `assetEntry` lists for a photo, which is what the small size asks for.
    private func setRendition(_ harness: Harness, assetID: String, width: Int, height: Int) {
        harness.transport.set("\(api)/assets/\(assetID)/renditions/x",
                              headers: ["content-type": "image/jpeg"],
                              body: fakeJPEG(width: width, height: height))
    }

    /// One photo old enough to sync, edited at 60 MP unless told otherwise.
    @discardableResult
    private func oneOldPhoto(_ harness: Harness, id: String = "p1", fileName: String = "P1000123.DNG",
                             cropped: (Int, Int) = (9528, 6328)) -> Date {
        let old = Date().addingTimeInterval(-7200)
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: id, fileName: fileName, added: old, edited: old, cropped: cropped),
        ]))
        return old
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

    // MARK: Photo size

    func testTheSmallSizeTakesLightroomsOwnRenditionAndNeverTheFullSizeDownload() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        oneOldPhoto(harness)
        // No full-size download is canned at all: reaching for one would 404 and fail the photo.
        setRendition(harness, assetID: "p1", width: 2048, height: 1360)

        let report = try await harness.engine.run(config(size: .small))
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.downgraded, 0, "2048 px is the size that was asked for, not a downgrade")
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.pixelWidth, 2048)
        XCTAssertTrue(harness.resizer.requests.isEmpty, "a rendition arrives at the size it was asked for")
        XCTAssertFalse(harness.transport.requests.contains { $0.host == "dl.lightroom.adobe.com" })
        // A rendition carries no file name, so the name Photos stores is the one a second Mac
        // looks the photo up by: the original's, as a JPEG.
        XCTAssertEqual(harness.importer.requests.first?.originalFileName, "P1000123.jpg")
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.fileName, "P1000123.jpg")
    }

    func testARenditionThatCannotBeFetchedFallsBackToTheFullSizeDownload() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        oneOldPhoto(harness)
        harness.transport.set("\(api)/assets/p1/renditions/x", status: 500, body: Data("boom".utf8))
        setDownload(harness, assetID: "p1", width: 9528, height: 6328)

        let report = try await harness.engine.run(config(size: .small))
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(harness.resizer.requests.map(\.maxLongEdge), [2048], "the full-size file is shrunk instead")
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.pixelWidth, 2048)
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("[warning]") && $0.contains("rendition") })
    }

    func testTheDefaultSizeShrinksWhatLightroomServedAndImportsTheSmallerFile() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        oneOldPhoto(harness)
        setDownload(harness, assetID: "p1", width: 9528, height: 6328)

        let report = try await harness.engine.run(config())
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.downgraded, 0)
        XCTAssertEqual(harness.resizer.requests.map(\.maxLongEdge), [PhotoSize.proDisplayXDRWidth])
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.pixelWidth, 6016, "a Pro Display XDR's width")
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.pixelHeight, 3996)
        XCTAssertEqual(harness.importer.requests.first?.fileURL.lastPathComponent, "p1-6016.jpg")
        // Both the download and the file made from it are cleaned up.
        let left = try FileManager.default.contentsOfDirectory(atPath: harness.directory.appendingPathComponent("downloads").path)
        XCTAssertEqual(left, [])
    }

    func testAPhotoAlreadyWithinTheSizeIsImportedUntouched() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        // A 12 MP photo is well inside Large, so nothing about it has to change.
        oneOldPhoto(harness, cropped: (4000, 3000))
        setDownload(harness, assetID: "p1", width: 4000, height: 3000)

        let report = try await harness.engine.run(config())
        XCTAssertEqual(report.synced, 1)
        XCTAssertTrue(harness.resizer.requests.isEmpty, "re-encoding a photo that is already small enough only costs quality")
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.pixelWidth, 4000)
        XCTAssertEqual(harness.importer.requests.first?.fileURL.lastPathComponent, "p1.jpg")
    }

    func testTheOriginalSizeKeepsEveryPixel() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        oneOldPhoto(harness)
        setDownload(harness, assetID: "p1", width: 9528, height: 6328)

        let report = try await harness.engine.run(config(size: .original))
        XCTAssertEqual(report.synced, 1)
        XCTAssertTrue(harness.resizer.requests.isEmpty)
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.pixelWidth, 9528)
    }

    func testAPhotoIsStillSyncedWhenItCannotBeResized() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        oneOldPhoto(harness)
        setDownload(harness, assetID: "p1", width: 9528, height: 6328)
        harness.resizer.error = NSError(domain: "FakeResizer", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "simulated ImageIO failure"])

        let report = try await harness.engine.run(config())
        XCTAssertEqual(report.synced, 1, "too large beats never synced")
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.pixelWidth, 9528)
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("[warning]") && $0.contains("resize") })
    }

    func testASmartPreviewIsOnlyReportedWhenTheSizeDoesNotExplainIt() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let old = Date().addingTimeInterval(-7200)
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "p1", fileName: "one.jpg", added: old, edited: old, cropped: (6000, 4000)),
        ]))
        // What a Lightroom Classic photo comes back as: a smart preview, far short of the edit.
        setDownload(harness, assetID: "p1", width: 2048, height: 1365)

        let full = try await harness.engine.run(config(size: .original))
        XCTAssertEqual(full.downgraded, 1)
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("[warning]") && $0.contains("smart previews") })

        // Asking for 2048 px and getting 2048 px is not a downgrade, whatever the edit's size.
        let second = try makeHarness()
        defer { try? FileManager.default.removeItem(at: second.directory) }
        second.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "p1", fileName: "one.jpg", added: old, edited: old, cropped: (6000, 4000)),
        ]))
        setRendition(second, assetID: "p1", width: 2048, height: 1365)
        let small = try await second.engine.run(config(size: .small))
        XCTAssertEqual(small.synced, 1)
        XCTAssertEqual(small.downgraded, 0)
        XCTAssertEqual(second.ledger.state.entries["p1"]?.downgraded, false)
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

// MARK: - The Photos check (what keeps a second Mac from importing everything again)

extension SyncEngineTests {
    func testPhotosAlreadyInTheLibraryAreRecordedWithoutDownloading() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let old = Date().addingTimeInterval(-7200)
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "known", fileName: "L1000133.DNG", sha: "sha-known", added: old, edited: old),
            assetEntry(id: "fresh", fileName: "L1000134.DNG", sha: "sha-fresh", added: old, edited: old),
        ]))
        // Lightroom serves a JPEG, so Photos holds "L1000133.jpg" even though the original is a DNG.
        harness.photoLibrary.identifiers["L1000133.jpg"] = "existing-local-id"
        setDownload(harness, assetID: "fresh", width: 4000, height: 3000)

        let report = try await harness.engine.run(config())
        XCTAssertEqual(report.foundInPhotos, 1)
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.failed, 0)

        // The known photo was neither downloaded nor imported, but it is recorded as synced.
        XCTAssertEqual(harness.importer.requests.map(\.originalFileName), ["fresh.jpg"])
        XCTAssertFalse(harness.transport.requests.contains { $0.absoluteString.hasSuffix("assets/known") })
        XCTAssertEqual(harness.ledger.state.entries["known"]?.photosLocalIdentifier, "existing-local-id")
        XCTAssertEqual(harness.ledger.state.entries["known"]?.fileName, "L1000133.jpg")
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("already in Photos") })

        // A second pass takes it from the ledger and asks Photos nothing more.
        harness.photoLibrary.queries.removeAll()
        let second = try await harness.engine.run(config())
        XCTAssertEqual(second.alreadySynced, 2)
        XCTAssertEqual(second.foundInPhotos, 0)
        XCTAssertTrue(harness.photoLibrary.queries.isEmpty)
    }

    func testPhotosQueryCarriesNameDateSizeAndAlbum() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let old = Date().addingTimeInterval(-7200)
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "p1", fileName: "DSC_3920.NEF", added: old, edited: old, cropped: (6016, 4016)),
        ]))
        setDownload(harness, assetID: "p1", width: 6016, height: 4016)

        _ = try await harness.engine.run(config(albumName: "Lightroom"))
        XCTAssertEqual(harness.photoLibrary.queries.count, 1)
        let query = try XCTUnwrap(harness.photoLibrary.queries.first)
        XCTAssertEqual(query.fileName, "DSC_3920.jpg")
        XCTAssertEqual(query.captureDate, AdobeDate.parse("2024-05-01T10:20:30"))
        XCTAssertEqual(query.pixelWidth, 6016)
        XCTAssertEqual(query.pixelHeight, 4016)
        XCTAssertEqual(query.albumName, "Lightroom")
        XCTAssertEqual(query.dateTolerance, SyncEngine.captureDateTolerance)
        XCTAssertGreaterThan(query.dateTolerance, 24 * 3600, "a time zone difference must not break the match")
    }

    func testPhotosCheckRunsBeforeTheWaitingRules() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let now = Date()
        // Just added, so the waiting rules would normally hold it back.
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "recent", fileName: "a.jpg", added: now.addingTimeInterval(-30)),
        ]))
        harness.photoLibrary.identifiers["a.jpg"] = "existing-local-id"

        let report = try await harness.engine.run(config(), now: now)
        XCTAssertEqual(report.foundInPhotos, 1)
        XCTAssertEqual(report.pending, 0)
        XCTAssertTrue(harness.ledger.contains(assetID: "recent"))
    }

    func testFailingPhotosCheckFallsBackToSyncing() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let old = Date().addingTimeInterval(-7200)
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "p1", fileName: "a.jpg", added: old, edited: old),
        ]))
        setDownload(harness, assetID: "p1", width: 4000, height: 3000)
        harness.photoLibrary.error = NSError(domain: "Photos", code: 1, userInfo: [NSLocalizedDescriptionKey: "no access"])

        let report = try await harness.engine.run(config())
        XCTAssertEqual(report.synced, 1, "a duplicate is better than a photo that never syncs")
        XCTAssertEqual(report.foundInPhotos, 0)
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("[warning]") && $0.contains("Could not check Photos") })
    }

    func testPhotoWithoutACaptureDateIsNotLookedUp() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let old = Date().addingTimeInterval(-7200)
        var entry = assetEntry(id: "p1", fileName: "a.jpg", added: old, edited: old)
        var payload = entry["asset"] as! [String: Any]
        var assetPayload = payload["payload"] as! [String: Any]
        assetPayload["captureDate"] = "0000-00-00T00:00:00"
        payload["payload"] = assetPayload
        entry["asset"] = payload
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [entry]))
        setDownload(harness, assetID: "p1", width: 4000, height: 3000)

        let report = try await harness.engine.run(config())
        XCTAssertTrue(harness.photoLibrary.queries.isEmpty, "without a date the query would scan the whole library")
        XCTAssertEqual(report.synced, 1)
    }
}

// MARK: - Keeping the configured Photos album in step

extension SyncEngineTests {
    /// Sets up one photo synced into `album`, and returns its Photos identifier.
    private func syncOnePhoto(into harness: Harness, album: String?) async throws -> String {
        let old = Date().addingTimeInterval(-7200)
        harness.transport.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "p1", fileName: "a.jpg", sha: "sha-1", added: old, edited: old),
        ]))
        setDownload(harness, assetID: "p1", width: 4000, height: 3000)
        let report = try await harness.engine.run(config(albumName: album))
        XCTAssertEqual(report.synced, 1)
        return try XCTUnwrap(harness.ledger.state.entries["p1"]?.photosLocalIdentifier)
    }

    func testDeletingTheAlbumInPhotosPutsSyncedPhotosBackIntoIt() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let identifier = try await syncOnePhoto(into: harness, album: "Lightroom")
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.photosAlbumName, "Lightroom")
        XCTAssertEqual(harness.photoLibrary.albums["Lightroom"], [identifier])

        // The user deletes the album in Photos. The photo itself stays in the library.
        harness.photoLibrary.albums.removeValue(forKey: "Lightroom")
        harness.photoLibrary.addCalls.removeAll()

        let report = try await harness.engine.run(config(albumName: "Lightroom"))
        XCTAssertEqual(report.synced, 0, "the photo is not downloaded or imported again")
        XCTAssertEqual(report.alreadySynced, 1)
        XCTAssertEqual(report.refiled, 1)
        XCTAssertEqual(harness.photoLibrary.albums["Lightroom"], [identifier], "the album is recreated")
        XCTAssertEqual(harness.importer.requests.count, 1)
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("back into “Lightroom”") && $0.contains("album was missing") })
    }

    func testChangingTheAlbumNameMovesSyncedPhotosIntoTheNewAlbum() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        // A half-typed name is exactly how the wrong album gets created in the first place.
        let identifier = try await syncOnePhoto(into: harness, album: "Lightroo")
        XCTAssertEqual(harness.photoLibrary.albums["Lightroo"], [identifier])

        let report = try await harness.engine.run(config(albumName: "Lightroom"))
        XCTAssertEqual(report.refiled, 1)
        XCTAssertEqual(report.synced, 0)
        XCTAssertEqual(harness.photoLibrary.albums["Lightroom"], [identifier])
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.photosAlbumName, "Lightroom")
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("album changed") })
    }

    func testAnUnchangedAlbumIsLeftAlone() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try await syncOnePhoto(into: harness, album: "Lightroom")
        harness.photoLibrary.addCalls.removeAll()

        let report = try await harness.engine.run(config(albumName: "Lightroom"))
        XCTAssertEqual(report.refiled, 0)
        XCTAssertTrue(harness.photoLibrary.addCalls.isEmpty, "a photo taken out of an existing album stays out")
    }

    func testWithoutAConfiguredAlbumNothingIsChecked() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try await syncOnePhoto(into: harness, album: nil)
        let report = try await harness.engine.run(config(albumName: nil))
        XCTAssertEqual(report.refiled, 0)
        XCTAssertTrue(harness.photoLibrary.albumExistsCalls.isEmpty)
    }

    func testPhotoDeletedFromTheLibraryIsReportedNotReimported() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let identifier = try await syncOnePhoto(into: harness, album: "Lightroom")
        harness.photoLibrary.albums.removeValue(forKey: "Lightroom")
        harness.photoLibrary.deletedIdentifiers.insert(identifier)

        let report = try await harness.engine.run(config(albumName: "Lightroom"))
        XCTAssertEqual(report.refiled, 0)
        XCTAssertEqual(report.synced, 0, "the ledger still says this photo was synced")
        XCTAssertEqual(harness.importer.requests.count, 1)
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("no longer in the Photos library") })
    }

    func testAlbumCheckFailureDoesNotStopThePass() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try await syncOnePhoto(into: harness, album: "Lightroom")
        harness.photoLibrary.error = NSError(domain: "Photos", code: 2, userInfo: [NSLocalizedDescriptionKey: "no access"])

        let report = try await harness.engine.run(config(albumName: "Lightroom"))
        XCTAssertEqual(report.refiled, 0)
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("[warning]") && $0.contains("Could not check the album") })
    }
}

extension SyncEngineTests {
    func testRefileReasonNamesWhatActuallyHappened() {
        func entry(album: String?) -> LedgerEntry {
            LedgerEntry(assetID: "a", shareID: "s", albumID: "b", fileName: nil, originalSHA256: nil,
                        photosLocalIdentifier: "local-1", photosAlbumName: album, syncedAt: Date(),
                        captureDate: nil, pixelWidth: nil, pixelHeight: nil, downgraded: false)
        }
        XCTAssertEqual(SyncEngine.refileReason([entry(album: "Lightroom")], albumName: "Lightroom"), "the album was missing")
        XCTAssertEqual(SyncEngine.refileReason([entry(album: "Lightroo")], albumName: "Lightroom"), "the album changed")
        XCTAssertEqual(SyncEngine.refileReason([entry(album: nil)], albumName: "Lightroom"),
                       "they were synced before the album was recorded")
    }
}
