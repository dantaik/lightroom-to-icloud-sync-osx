import XCTest
@testable import LightroomSyncCore

/// Wraps a transport and watches what the download host is asked to do: how many downloads are in
/// flight at once, and how far they get before the pass is stopped.
private final class WatchingTransport: HTTPTransport, @unchecked Sendable {
    let inner: FakeTransport
    /// Held open until `release()`, so a test can decide when downloads finish.
    private let gate = Gate()
    private let lock = NSLock()
    private var active = 0
    private(set) var peakActive = 0
    private(set) var started = 0
    var holdsDownloads = false
    /// A fake download returns instantly, which would let each task finish before the next one
    /// starts and hide any overlap. A small wait makes the concurrency observable.
    var downloadDelay: Duration = .zero

    init(_ inner: FakeTransport) { self.inner = inner }

    /// Blocks until the test lets downloads through. Used to hold a pass open mid-fetch.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private var opened = false
        private let lock = NSLock()

        func open() {
            lock.withLock {
                guard !opened else { return }
                opened = true
            }
            for _ in 0..<64 { semaphore.signal() }
        }

        func wait() async {
            if lock.withLock({ opened }) { return }
            // Poll rather than block a cooperative thread, so a held pass stays cancellable.
            while !lock.withLock({ opened }), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func release() { gate.open() }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        guard url.host == "dl.lightroom.adobe.com" else { return try await inner.get(url, headers: headers) }
        lock.withLock {
            active += 1
            started += 1
            peakActive = max(peakActive, active)
        }
        defer { lock.withLock { active -= 1 } }
        if holdsDownloads { await gate.wait() }
        if downloadDelay > .zero { try? await Task.sleep(for: downloadDelay) }
        try Task.checkCancellation()
        return try await inner.get(url, headers: headers)
    }
}

/// Answers a given number of 429s before serving the real response.
private final class ThrottlingTransport: HTTPTransport, @unchecked Sendable {
    let inner: FakeTransport
    private let lock = NSLock()
    private var remaining: Int
    var retryAfter: String?
    private(set) var attempts = 0

    init(_ inner: FakeTransport, throttleTimes: Int) {
        self.inner = inner
        self.remaining = throttleTimes
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        guard url.host == "dl.lightroom.adobe.com" else { return try await inner.get(url, headers: headers) }
        let throttle: Bool = lock.withLock {
            attempts += 1
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if throttle {
            var headers = ["content-type": "text/plain"]
            if let retryAfter { headers["retry-after"] = retryAfter }
            return HTTPResponse(status: 429, headers: headers, body: Data(), finalURL: url)
        }
        return try await inner.get(url, headers: headers)
    }
}

final class SyncEngineConcurrencyTests: XCTestCase {
    private let share = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let album = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private var api: String { "https://lightroom.adobe.com/v2c/spaces/\(share)" }
    private var assetsURL: String { "\(api)/albums/\(album)/assets?embed=asset&subtype=image%3Bvideo&limit=500" }

    private struct Harness {
        let fake: FakeTransport
        let importer: FakeImporter
        let photoLibrary: FakePhotoLibrary
        let sink: RecordingSink
        let ledger: Ledger
        let directory: URL
        var downloads: URL { directory.appendingPathComponent("downloads") }
    }

    /// Sets up a share with `count` photos, all old enough to sync.
    private func makeHarness(photoCount: Int, sharedSHA: Bool = false) throws -> Harness {
        let directory = try makeTemporaryDirectory()
        let fake = FakeTransport()
        fake.setJSON(api, #"{"id": "\#(share)", "type": "space", "createdOnClient": "t", "payload": {"download": true}}"#)
        fake.setJSON("\(api)/resources", #"{"base": "x", "resources": [{"id": "\#(album)", "type": "album", "payload": {"name": "Test album"}}]}"#)
        let old = Date().addingTimeInterval(-7200)
        var entries: [[String: Any]] = []
        for index in 1...photoCount {
            entries.append(assetEntry(id: "p\(index)", fileName: "P\(index).DNG",
                                      sha: sharedSHA ? "same" : "sha-\(index)",
                                      added: old, edited: old, cropped: (4000, 3000)))
            fake.set("https://dl.lightroom.adobe.com/spaces/\(share)/assets/p\(index)",
                     headers: ["content-type": "image/jpeg",
                               "content-disposition": "attachment; filename=\"p\(index).jpg\""],
                     body: fakeJPEG(width: 4000, height: 3000))
        }
        fake.setJSON(assetsURL, assetsPageJSON(entries: entries))
        let importer = FakeImporter()
        let photoLibrary = FakePhotoLibrary()
        importer.library = photoLibrary
        let ledger = try Ledger(fileURL: directory.appendingPathComponent("ledger.json"))
        return Harness(fake: fake, importer: importer, photoLibrary: photoLibrary,
                       sink: RecordingSink(), ledger: ledger, directory: directory)
    }

    private func makeEngine(_ harness: Harness, transport: HTTPTransport? = nil,
                            backoff: [Duration] = [.milliseconds(1), .milliseconds(1)]) -> SyncEngine {
        SyncEngine(client: LightroomGalleryClient(transport: transport ?? harness.fake, throttleBackoff: backoff),
                   ledger: harness.ledger, importer: harness.importer, photoLibrary: harness.photoLibrary,
                   resizer: FakeResizer(), metadataWriter: FakeMetadataWriter(),
                   downloadDirectory: harness.downloads, sink: harness.sink)
    }

    private func config(concurrency: Int) -> SyncConfiguration {
        SyncConfiguration(shareLink: "https://lightroom.adobe.com/shares/\(share)",
                          photosAlbumName: "Lightroom", checkInterval: 15 * 60,
                          downloadConcurrency: concurrency)
    }

    private func filesLeft(_ harness: Harness) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: harness.downloads.path)) ?? []).sorted()
    }

    // MARK: - Fetching several at once

    func testPhotosAreFetchedSeveralAtOnce() async throws {
        let harness = try makeHarness(photoCount: 12)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let watching = WatchingTransport(harness.fake)
        watching.downloadDelay = .milliseconds(20)

        let report = try await makeEngine(harness, transport: watching).run(config(concurrency: 5))
        XCTAssertEqual(report.synced, 12)
        XCTAssertGreaterThan(watching.peakActive, 1, "downloads must overlap")
        XCTAssertLessThanOrEqual(watching.peakActive, 5, "and never exceed what was asked for")
    }

    func testAConcurrencyOfOneFetchesStrictlyOneAtATime() async throws {
        let harness = try makeHarness(photoCount: 6)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let watching = WatchingTransport(harness.fake)
        watching.downloadDelay = .milliseconds(20)

        let report = try await makeEngine(harness, transport: watching).run(config(concurrency: 1))
        XCTAssertEqual(report.synced, 6)
        XCTAssertEqual(watching.peakActive, 1)
    }

    func testEveryPhotoIsSyncedExactlyOnceWhateverTheWidth() async throws {
        for width in [1, 3, 10] {
            let harness = try makeHarness(photoCount: 9)
            defer { try? FileManager.default.removeItem(at: harness.directory) }

            let report = try await makeEngine(harness).run(config(concurrency: width))
            XCTAssertEqual(report.synced, 9, "width \(width)")
            XCTAssertEqual(harness.ledger.syncedCount, 9, "width \(width)")
            XCTAssertEqual(Set(harness.importer.requests.map(\.originalFileName)).count, 9, "width \(width)")
            XCTAssertEqual(filesLeft(harness), [], "width \(width): nothing left behind")
        }
    }

    /// The duplicate check reads the ledger, and the entry that answers it is not written until a
    /// photo has been imported. Fetching several at once must not let the same original through
    /// twice while the first one is still in flight.
    func testTheSameOriginalIsNotFetchedTwiceInParallel() async throws {
        let harness = try makeHarness(photoCount: 5, sharedSHA: true)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        let report = try await makeEngine(harness).run(config(concurrency: 5))
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.duplicates, 4)
        XCTAssertEqual(harness.importer.requests.count, 1, "the same original was imported once")
    }

    /// The same photograph can reach the album as two assets that share no `sha256` — Lightroom
    /// reports none at all for some imports, and a different one for each copy of others. Then the
    /// only thing saying they are one photograph is the file name and capture time, which is what
    /// the Photos lookup searches the library on. That lookup cannot see a photo that is still
    /// downloading, so fetching several at once has to hold the second one back just as it does
    /// for a shared original. Before it did, both were imported: one photo, twice in Photos, under
    /// the same file name and the same metadata.
    func testTheSamePhotographIsNotFetchedTwiceInParallelWithoutAHash() async throws {
        let harness = try makeHarness(photoCount: 2)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let old = Date().addingTimeInterval(-7200)
        harness.fake.setJSON(assetsURL, assetsPageJSON(entries: [
            assetEntry(id: "p1", fileName: "DSC_0100.NEF", added: old, edited: old),
            assetEntry(id: "p2", fileName: "DSC_0100.NEF", added: old, edited: old),
        ]))
        // Lightroom names the JPEG it serves after the original, whichever asset asked for it.
        for id in ["p1", "p2"] {
            harness.fake.set("https://dl.lightroom.adobe.com/spaces/\(share)/assets/\(id)",
                             headers: ["content-type": "image/jpeg",
                                       "content-disposition": "attachment; filename=\"DSC_0100.jpg\""],
                             body: fakeJPEG(width: 4000, height: 3000))
        }

        let report = try await makeEngine(harness).run(config(concurrency: 5))
        XCTAssertEqual(harness.importer.requests.count, 1, "the same photograph reached Photos once")
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.duplicates, 1)
        XCTAssertEqual(harness.ledger.state.entries["p2"]?.photosLocalIdentifier,
                       harness.ledger.state.entries["p1"]?.photosLocalIdentifier,
                       "both assets are recorded against the one photo in Photos")
    }

    func testProgressCountsEveryCandidateOnce() async throws {
        let harness = try makeHarness(photoCount: 7)
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        _ = try await makeEngine(harness).run(config(concurrency: 4))
        XCTAssertEqual(harness.sink.progress.first?.0, 0)
        XCTAssertEqual(harness.sink.progress.last.map { [$0.0, $0.1] }, [7, 7])
        XCTAssertEqual(harness.sink.progress.map(\.0), Array(0...7), "one step per candidate, in order")
    }

    // MARK: - Stopping and starting again

    func testStoppingMidPassLeavesNoDownloadsBehind() async throws {
        let harness = try makeHarness(photoCount: 8)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let watching = WatchingTransport(harness.fake)
        watching.holdsDownloads = true
        let engine = makeEngine(harness, transport: watching)

        let task = Task { try await engine.run(config(concurrency: 4)) }
        // Wait until the window is full, so the stop lands with downloads genuinely in flight.
        while watching.started < 4 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        watching.release()
        _ = try? await task.value

        XCTAssertEqual(filesLeft(harness), [], "a stop must not strand the files it was fetching")
    }

    func testStoppingMidPassKeepsWhatWasAlreadySyncedAndNothingMore() async throws {
        let harness = try makeHarness(photoCount: 8)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let watching = WatchingTransport(harness.fake)
        watching.holdsDownloads = true
        let engine = makeEngine(harness, transport: watching)

        let task = Task { try await engine.run(config(concurrency: 3)) }
        while watching.started < 3 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        watching.release()
        _ = try? await task.value

        // Whatever the stop caught, the ledger only ever names photos that really reached Photos.
        let recorded = Set(harness.ledger.state.entries.keys)
        let imported = Set(harness.importer.requests.compactMap(\.originalFileName))
        XCTAssertLessThan(recorded.count, 8, "the pass did not finish")
        for assetID in recorded {
            XCTAssertTrue(imported.contains("\(assetID).jpg"),
                          "\(assetID) is in the ledger but was never imported")
        }
    }

    /// A stop, then a fresh start: the photos that did not make it are picked up, and the ones
    /// that did are not fetched again.
    func testAStoppedPassIsResumedByTheNextOne() async throws {
        let harness = try makeHarness(photoCount: 8)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let watching = WatchingTransport(harness.fake)
        watching.holdsDownloads = true

        let task = Task { try await self.makeEngine(harness, transport: watching).run(self.config(concurrency: 3)) }
        while watching.started < 3 { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        watching.release()
        _ = try? await task.value
        let syncedBeforeStop = harness.ledger.syncedCount

        // A second engine over the same ledger and directory, the way a relaunch would be.
        let resumed = try await makeEngine(harness).run(config(concurrency: 3))
        XCTAssertEqual(harness.ledger.syncedCount, 8, "everything is synced once the pass completes")
        XCTAssertEqual(resumed.alreadySynced, syncedBeforeStop, "what was done is not done again")
        XCTAssertEqual(filesLeft(harness), [])
        // Nothing was imported twice.
        XCTAssertEqual(Set(harness.importer.requests.map(\.originalFileName)).count,
                       harness.importer.requests.count)
    }

    func testAPassClearsWhatAnEarlierStopLeftInTheDownloadDirectory() async throws {
        let harness = try makeHarness(photoCount: 2)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try FileManager.default.createDirectory(at: harness.downloads, withIntermediateDirectories: true)
        let orphan = harness.downloads.appendingPathComponent("abandoned.jpg")
        try fakeJPEG(width: 10, height: 10).write(to: orphan)

        _ = try await makeEngine(harness).run(config(concurrency: 2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(filesLeft(harness), [])
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("unfinished download") })
    }

    /// The ledger is written after the import, so a stop in between leaves a photo in Photos that
    /// the ledger does not know about. The Photos lookup is what recovers it.
    func testAPhotoImportedButNotRecordedIsRecoveredWithoutDownloadingItAgain() async throws {
        let harness = try makeHarness(photoCount: 1)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        // Stand in for the interrupted pass: Photos holds it, the ledger does not.
        harness.photoLibrary.identifiers["P1.jpg"] = "imported-before-the-stop"
        let watching = WatchingTransport(harness.fake)

        let report = try await makeEngine(harness, transport: watching).run(config(concurrency: 5))
        XCTAssertEqual(report.foundInPhotos, 1)
        XCTAssertEqual(report.synced, 0)
        XCTAssertEqual(watching.started, 0, "it was already in Photos, so nothing was downloaded")
        XCTAssertEqual(harness.ledger.state.entries["p1"]?.photosLocalIdentifier, "imported-before-the-stop")
    }

    // MARK: - Being told to slow down

    func testAThrottledDownloadIsWaitedOutRatherThanCountedAsAFailure() async throws {
        let harness = try makeHarness(photoCount: 1)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let throttling = ThrottlingTransport(harness.fake, throttleTimes: 2)

        let report = try await makeEngine(harness, transport: throttling).run(config(concurrency: 5))
        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(throttling.attempts, 3, "two refusals, then the photo")
        XCTAssertTrue(harness.sink.lines.contains { $0.contains("asked for") && $0.contains("waiting") },
                      "the log has to say the share is throttling, so the width can be lowered")
    }

    func testThrottlingThatNeverLetsUpIsAFailedPhotoNotAHungPass() async throws {
        let harness = try makeHarness(photoCount: 1)
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        let throttling = ThrottlingTransport(harness.fake, throttleTimes: .max)

        let report = try await makeEngine(harness, transport: throttling).run(config(concurrency: 5))
        XCTAssertEqual(report.synced, 0)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(throttling.attempts, 3, "the two backoffs, and no more")
        XCTAssertEqual(filesLeft(harness), [])
    }

    func testRetryAfterIsReadWhenTheServerNamesAWait() {
        XCTAssertEqual(LightroomGalleryClient.retryAfter("30"), .seconds(30))
        XCTAssertEqual(LightroomGalleryClient.retryAfter(" 5 "), .seconds(5))
        XCTAssertNil(LightroomGalleryClient.retryAfter(nil))
        XCTAssertNil(LightroomGalleryClient.retryAfter("0"))
        XCTAssertNil(LightroomGalleryClient.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT"))
        XCTAssertNil(LightroomGalleryClient.retryAfter("900"), "a wait that long is worse than our own backoff")
    }
}
