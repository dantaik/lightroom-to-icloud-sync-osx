import XCTest
@testable import LightroomSyncCore

final class AdobeJSONTests: XCTestCase {
    func testStripsGuardPrefix() throws {
        let stripped = AdobeJSON.stripGuardPrefix(Data("while (1) {}\n{\"a\": 1}".utf8))
        XCTAssertEqual(String(decoding: stripped, as: UTF8.self), "{\"a\": 1}")
        XCTAssertEqual(AdobeJSON.stripGuardPrefix(Data("  [1]".utf8)), Data("[1]".utf8))
        XCTAssertEqual(AdobeJSON.stripGuardPrefix(Data()), Data())
    }

    func testDecodesGuardedJSON() throws {
        struct Probe: Decodable { let a: Int }
        let probe = try AdobeJSON.decode(Probe.self, from: Data("while (1) {}\n{\"a\": 42}".utf8))
        XCTAssertEqual(probe.a, 42)
    }

    func testParsesUTCTimestampsWithAnyFractionLength() {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let expected = calendar.date(from: DateComponents(year: 2024, month: 9, day: 18, hour: 21, minute: 7, second: 30))!
        XCTAssertEqual(AdobeDate.parse("2024-09-18T21:07:30Z"), expected)
        XCTAssertEqual(AdobeDate.parse("2024-09-18T21:07:30.325Z")!.timeIntervalSince(expected), 0.325, accuracy: 0.001)
        XCTAssertEqual(AdobeDate.parse("2024-09-18T21:07:30.384971Z")!.timeIntervalSince(expected), 0.384971, accuracy: 0.001)
        XCTAssertEqual(AdobeDate.parse("2024-09-18T23:07:30+02:00"), expected)
    }

    func testParsesLocalTimestampInGivenZone() {
        let zone = TimeZone(secondsFromGMT: -7 * 3600)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let expected = calendar.date(from: DateComponents(year: 2013, month: 9, day: 7, hour: 19, minute: 47, second: 13))!
        XCTAssertEqual(AdobeDate.parse("2013-09-07T19:47:13", localTimeZone: zone), expected)
    }

    func testRejectsPlaceholdersAndGarbage() {
        XCTAssertNil(AdobeDate.parse("0000-00-00T00:00:00"))
        XCTAssertNil(AdobeDate.parse(nil))
        XCTAssertNil(AdobeDate.parse("yesterday"))
        XCTAssertNil(AdobeDate.parse("2024-09-18T21:07:30X"))
    }
}
