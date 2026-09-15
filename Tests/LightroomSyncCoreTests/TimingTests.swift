import XCTest
@testable import LightroomSyncCore

final class TimingTests: XCTestCase {
    func testDurationsAreDescribedAtAReadableScale() {
        XCTAssertEqual(Stopwatch.describe(.milliseconds(420)), "420 ms")
        XCTAssertEqual(Stopwatch.describe(.seconds(9)), "9.00 s")
        XCTAssertEqual(Stopwatch.describe(.milliseconds(12_340)), "12.3 s")
        XCTAssertEqual(Stopwatch.describe(.seconds(125)), "2 min 05.0 s")
        XCTAssertEqual(Stopwatch.describe(.zero), "0 ms")
    }

    func testAStopwatchMovesForward() {
        let clock = Stopwatch()
        XCTAssertGreaterThanOrEqual(clock.elapsed, .zero)
        XCTAssertGreaterThan(Stopwatch.seconds(.milliseconds(1500)), 1.4)
    }

    func testAPhotosStepsAddUpAndOnlyTheNonZeroOnesAreNamed() {
        var timings = PhotoTimings()
        timings.lookup = .seconds(3)
        timings.download = .seconds(8)
        timings.importing = .milliseconds(300)

        XCTAssertEqual(timings.total, .milliseconds(11_300))
        XCTAssertEqual(timings.breakdown, "lookup 3.00 s, download 8.00 s, import 300 ms")
    }

    func testStepsTooFastToMatterAreLeftOutOfTheBreakdown() {
        var timings = PhotoTimings()
        timings.download = .seconds(4)
        timings.ledger = .microseconds(30)
        XCTAssertEqual(timings.breakdown, "download 4.00 s", "a 30 µs write is noise, not a finding")
        XCTAssertEqual(PhotoTimings().breakdown, "")
    }

    func testThePassSummaryNamesTheSlowestStepFirst() {
        var timings = SyncTimings()
        timings.listing = .seconds(1)
        var photo = PhotoTimings()
        photo.lookup = .seconds(30)
        photo.didLookup = true
        photo.download = .seconds(5)
        photo.didDownload = true
        photo.importing = .milliseconds(200)
        photo.didImport = true
        timings.add(photo)
        timings.add(photo)

        XCTAssertEqual(timings.photosLookups, 2)
        XCTAssertEqual(timings.downloads, 2)
        XCTAssertEqual(timings.imports, 2)
        XCTAssertEqual(timings.photosLookup, .seconds(60))
        XCTAssertEqual(timings.summary,
                       "Photos lookups 1 min 00.0 s (×2), downloads 10.0 s (×2), listing 1.00 s, imports 400 ms (×2)")
    }

    func testAPassThatDidNothingSaysSoRatherThanListingZeroes() {
        XCTAssertEqual(SyncTimings().summary, "too little to measure")
    }

    /// The point of the whole thing: a slow pass has to say what it was slow because of.
    func testASlowPassNamesTheStepThatDominatedIt() throws {
        var timings = SyncTimings()
        timings.listing = .seconds(1)
        var photo = PhotoTimings()
        photo.lookup = .seconds(30)
        photo.didLookup = true
        photo.download = .seconds(4)
        photo.didDownload = true
        timings.add(photo)

        let diagnosis = try XCTUnwrap(timings.diagnosis)
        XCTAssertTrue(diagnosis.hasPrefix("Most of that was Photos lookups (86%)"), diagnosis)
        XCTAssertTrue(diagnosis.contains("searched for across the library"), diagnosis)
    }

    func testAPassWithNoOneCulpritDoesNotInventOne() {
        var timings = SyncTimings()
        timings.listing = .seconds(4)
        timings.download = .seconds(4)
        timings.resize = .seconds(4)
        XCTAssertNil(timings.diagnosis, "nothing took half the pass, so there is nothing to point at")
    }

    func testAQuickPassIsNotDiagnosed() {
        var timings = SyncTimings()
        timings.download = .milliseconds(80)
        XCTAssertNil(timings.diagnosis, "80 ms is not a complaint")
    }
}
