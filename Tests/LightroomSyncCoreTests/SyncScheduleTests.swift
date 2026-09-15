import XCTest
@testable import LightroomSyncCore

final class SyncScheduleTests: XCTestCase {
    let schedule = SyncSchedule(interval: 15 * 60, settingsSettleTime: 8)

    func testFirstPassStartsImmediately() {
        XCTAssertEqual(schedule.decision(now: Date(), lastAttempt: nil, lastSettingsChange: nil), .start)
    }

    func testWaitsForTheInterval() {
        let now = Date()
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: now.addingTimeInterval(-60), lastSettingsChange: nil), .waitForInterval)
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: now.addingTimeInterval(-900), lastSettingsChange: nil), .start)
    }

    func testAPassNeverStartsWhileTheSettingsAreBeingTyped() {
        let now = Date()
        // Typing "Lightroom" must not let a pass run with "Lightroo".
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: nil, lastSettingsChange: now.addingTimeInterval(-1)), .waitForSettings)
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: nil, lastSettingsChange: now.addingTimeInterval(-7.9)), .waitForSettings)
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: nil, lastSettingsChange: now.addingTimeInterval(-8)), .start)
    }

    func testSettingsGateOutranksAnOverdueInterval() {
        let now = Date()
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: now.addingTimeInterval(-3600),
                                         lastSettingsChange: now.addingTimeInterval(-2)), .waitForSettings)
    }

    func testAClockJumpBackwardsDoesNotWedgeTheLoop() {
        let now = Date()
        XCTAssertEqual(schedule.decision(now: now, lastAttempt: nil, lastSettingsChange: now.addingTimeInterval(600)), .start)
    }

    func testDefaultSettleTimeIsLongerThanTypingAnAlbumName() {
        XCTAssertGreaterThanOrEqual(SyncSchedule.defaultSettingsSettleTime, 5)
    }
}
