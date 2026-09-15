import XCTest
@testable import LightroomSyncCore

final class SyncPolicyTests: XCTestCase {
    private func photo(added: Date?, edited: Date?) -> LightroomPhoto {
        LightroomPhoto(assetID: "a", subtype: "image", fileName: "a.jpg", originalSHA256: nil,
                       originalWidth: nil, originalHeight: nil, croppedWidth: nil, croppedHeight: nil,
                       captureDate: nil, addedToAlbumAt: added, lastEditedAt: edited, hasEdits: true)
    }

    func testWaitsUntilPhotoHasBeenInAlbumForTheInterval() {
        let now = Date()
        let policy = SyncPolicy(minimumAgeInAlbum: 15 * 60, settleTime: 120)
        XCTAssertEqual(policy.decision(for: photo(added: now.addingTimeInterval(-5 * 60), edited: nil), firstSeen: now, now: now),
                       .wait("added 5 min ago, eligible in 10 min"))
        XCTAssertEqual(policy.decision(for: photo(added: now.addingTimeInterval(-16 * 60), edited: nil), firstSeen: now, now: now), .sync)
    }

    func testUsesFirstSeenWhenLightroomGivesNoTimestamp() {
        let now = Date()
        let policy = SyncPolicy(minimumAgeInAlbum: 600, settleTime: 0)
        XCTAssertEqual(policy.decision(for: photo(added: nil, edited: nil), firstSeen: now, now: now), .wait("added 0 min ago, eligible in 10 min"))
        XCTAssertEqual(policy.decision(for: photo(added: nil, edited: nil), firstSeen: now.addingTimeInterval(-700), now: now), .sync)
    }

    func testRecentEditWaitsToSettle() {
        let now = Date()
        let policy = SyncPolicy(minimumAgeInAlbum: 60, settleTime: 120)
        let old = now.addingTimeInterval(-3600)
        if case .wait(let reason) = policy.decision(for: photo(added: old, edited: now.addingTimeInterval(-30)), firstSeen: old, now: now) {
            XCTAssertTrue(reason.contains("settle"))
        } else {
            XCTFail("expected to wait for edits to settle")
        }
        XCTAssertEqual(policy.decision(for: photo(added: old, edited: now.addingTimeInterval(-121)), firstSeen: old, now: now), .sync)
    }

    func testIgnoreDelaysSyncsImmediately() {
        let now = Date()
        let policy = SyncPolicy(minimumAgeInAlbum: 3600, settleTime: 3600, ignoreDelays: true)
        XCTAssertEqual(policy.decision(for: photo(added: now, edited: now), firstSeen: now, now: now), .sync)
    }
}
