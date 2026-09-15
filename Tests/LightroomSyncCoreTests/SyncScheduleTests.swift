import XCTest
@testable import LightroomSyncCore

final class SyncScheduleTests: XCTestCase {
    let schedule = SyncSchedule(interval: 15 * 60)

    func testFirstPassStartsImmediately() {
        XCTAssertEqual(schedule.decision(now: Date(), lastAttempt: nil), .start)
    }

    func testWaitsForTheInterval() {
        let now = Date()
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: now.addingTimeInterval(-60)), .waitForInterval)
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: now.addingTimeInterval(-899)), .waitForInterval)
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: now.addingTimeInterval(-900)), .start)
    }

    func testAClockJumpBackwardsDoesNotWedgeTheLoop() {
        let now = Date()
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: now.addingTimeInterval(3600)), .start)
    }

    func testShouldStartMatchesTheDecision() {
        let now = Date()
        XCTAssertTrue(schedule.shouldStart(now: now, lastAttempt: nil))
        XCTAssertFalse(schedule.shouldStart(now: now, lastAttempt: now))
    }
}
