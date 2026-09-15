import XCTest
@testable import LightroomSyncCore

final class SyncSettingsTests: XCTestCase {
    private func settings(link: String = "https://adobe.ly/abc", album: String? = nil,
                          photos: String = "Lightroom", value: Int = 15,
                          unit: IntervalUnit = .minutes) -> SyncSettings {
        SyncSettings(shareLink: link, albumID: album, photosAlbumName: photos,
                     intervalValue: value, intervalUnit: unit)
    }

    func testNormalizationTrimsAndClamps() {
        let messy = SyncSettings(shareLink: "  https://adobe.ly/abc\n", albumID: "",
                                 photosAlbumName: " Lightroom ", intervalValue: 99_999, intervalUnit: .minutes)
        let clean = messy.normalized
        XCTAssertEqual(clean.shareLink, "https://adobe.ly/abc")
        XCTAssertNil(clean.albumID)
        XCTAssertEqual(clean.photosAlbumName, "Lightroom")
        XCTAssertEqual(clean.intervalValue, IntervalUnit.minutes.range.upperBound)
        XCTAssertEqual(settings(value: 0).normalized.intervalValue, 1)
        XCTAssertEqual(settings(value: 99, unit: .days).normalized.intervalValue, IntervalUnit.days.range.upperBound)
        XCTAssertEqual(clean.normalized, clean, "normalizing twice changes nothing")
    }

    func testIntervalInEveryUnit() {
        XCTAssertEqual(settings(value: 15, unit: .minutes).checkInterval, 15 * 60)
        XCTAssertEqual(settings(value: 2, unit: .hours).checkInterval, 2 * 3600)
        XCTAssertEqual(settings(value: 3, unit: .days).checkInterval, 3 * 86_400)
        // Clamping applies to the interval too, so a pass is never scheduled on a silly number.
        XCTAssertEqual(settings(value: 9_999, unit: .hours).checkInterval, 48 * 3600)
    }

    func testIntervalDescriptionReadsNaturally() {
        XCTAssertEqual(settings(value: 15, unit: .minutes).intervalDescription, "15 minutes")
        XCTAssertEqual(settings(value: 1, unit: .minutes).intervalDescription, "1 minute")
        XCTAssertEqual(settings(value: 1, unit: .hours).intervalDescription, "1 hour")
        XCTAssertEqual(settings(value: 2, unit: .hours).intervalDescription, "2 hours")
        XCTAssertEqual(settings(value: 1, unit: .days).intervalDescription, "1 day")
    }

    func testAnIntervalStoredAsMinutesBecomesTheLargestExactUnit() {
        func interval(_ minutes: Int) -> String {
            let parsed = SyncSettings.interval(fromMinutes: minutes)
            return "\(parsed.value) \(parsed.unit.rawValue)"
        }
        XCTAssertEqual(interval(15), "15 minutes")
        XCTAssertEqual(interval(90), "90 minutes")
        XCTAssertEqual(interval(60), "1 hours")
        XCTAssertEqual(interval(120), "2 hours")
        XCTAssertEqual(interval(1440), "1 days")
        XCTAssertEqual(interval(4320), "3 days")
        XCTAssertEqual(interval(0), "15 minutes", "an unset value falls back to the default")
        XCTAssertEqual(interval(-5), "15 minutes")
        XCTAssertEqual(interval(100_000), "240 minutes", "beyond every range, clamped to the minutes cap")
    }

    func testPhotoSizeDefaultsToTheLargestAndReachesTheEngine() {
        XCTAssertEqual(SyncSettings.empty.photoSize, .large, "a fresh install syncs at a Pro Display XDR's width")
        XCTAssertEqual(settings().normalized.photoSize, .large)

        var small = settings()
        small.photoSize = .small
        XCTAssertEqual(small.normalized.photoSize, .small)
        XCTAssertEqual(small.syncConfiguration(ignoreDelays: false).photoSize, .small)
        XCTAssertNotEqual(small.normalized, settings().normalized, "changing the size is an unsaved change")
    }

    func testUnitNamesAndClamping() {
        XCTAssertEqual(IntervalUnit.allCases, [.minutes, .hours, .days])
        XCTAssertEqual(IntervalUnit.hours.name(for: 1), "hour")
        XCTAssertEqual(IntervalUnit.hours.name(for: 5), "hours")
        XCTAssertEqual(IntervalUnit.days.clamp(0), 1)
        XCTAssertEqual(IntervalUnit.days.clamp(500), 30)
        XCTAssertEqual(IntervalUnit.minutes.seconds, 60)
        XCTAssertEqual(IntervalUnit.hours.seconds, 3600)
        XCTAssertEqual(IntervalUnit.days.seconds, 86_400)
    }

    func testIsConfiguredNeedsAShareLink() {
        XCTAssertFalse(SyncSettings.empty.isConfigured)
        XCTAssertFalse(settings(link: "   ").isConfigured)
        XCTAssertTrue(settings().isConfigured)
    }

    func testSyncConfigurationUsesTheNormalizedValues() {
        let configuration = settings(album: "album-1", photos: "  Lightroom  ", value: 30)
            .syncConfiguration(ignoreDelays: true)
        XCTAssertEqual(configuration.shareLink, "https://adobe.ly/abc")
        XCTAssertEqual(configuration.preferredAlbumID, "album-1")
        XCTAssertEqual(configuration.photosAlbumName, "Lightroom")
        XCTAssertEqual(configuration.checkInterval, 30 * 60)
        XCTAssertTrue(configuration.ignoreDelays)
    }

    func testAnEmptyPhotosAlbumMeansTheLibraryOnly() {
        XCTAssertNil(settings(photos: "   ").syncConfiguration(ignoreDelays: false).photosAlbumName)
    }
}

final class SyncSettingsEditorTests: XCTestCase {
    private let saved = SyncSettings(shareLink: "https://adobe.ly/abc", albumID: "album-1",
                                     photosAlbumName: "Lightroom", intervalValue: 15, intervalUnit: .minutes)

    func testNothingIsReadyBeforeTheFirstSave() {
        var editor = SyncSettingsEditor(saved: nil)
        XCTAssertNil(editor.saved)
        XCTAssertFalse(editor.isReadyToSync, "an unsaved draft must not drive a background pass")
        XCTAssertFalse(editor.hasUnsavedChanges)

        editor.draft.shareLink = "https://adobe.ly/abc"
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertFalse(editor.isReadyToSync, "typing alone is not enough")
        XCTAssertNil(editor.saved, "typing does not save")

        editor.save()
        XCTAssertEqual(editor.saved?.shareLink, "https://adobe.ly/abc")
        XCTAssertTrue(editor.isReadyToSync)
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testAHalfTypedAlbumNameNeverReachesTheSavedSettings() {
        var editor = SyncSettingsEditor(saved: saved)
        editor.draft.photosAlbumName = "Lightroo"
        XCTAssertEqual(editor.saved?.photosAlbumName, "Lightroom")
        XCTAssertFalse(editor.isReadyToSync, "a pass must wait until the edit is saved or reverted")

        editor.draft.photosAlbumName = "Lightroom Portraits"
        editor.save()
        XCTAssertEqual(editor.saved?.photosAlbumName, "Lightroom Portraits")
        XCTAssertTrue(editor.isReadyToSync)
    }

    func testRevertGoesBackToTheSavedSettings() {
        var editor = SyncSettingsEditor(saved: saved)
        editor.draft.shareLink = "nonsense"
        editor.draft.intervalValue = 6
        editor.draft.intervalUnit = .hours
        editor.revert()
        XCTAssertEqual(editor.draft, saved)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertTrue(editor.isReadyToSync)
    }

    func testRevertingWithNothingSavedClearsTheDraft() {
        var editor = SyncSettingsEditor(saved: nil)
        editor.draft.shareLink = "https://adobe.ly/abc"
        editor.revert()
        XCTAssertEqual(editor.draft, .empty)
    }

    func testCosmeticEditsAreNotChanges() {
        var editor = SyncSettingsEditor(saved: saved)
        editor.draft.photosAlbumName = "  Lightroom  "
        XCTAssertFalse(editor.hasUnsavedChanges, "trailing spaces are not an edit")
        XCTAssertTrue(editor.isReadyToSync)
    }

    func testSavingNormalizesTheDraftInPlace() {
        var editor = SyncSettingsEditor(saved: nil)
        editor.draft = SyncSettings(shareLink: " https://adobe.ly/abc ", albumID: nil,
                                    photosAlbumName: " Trips ", intervalValue: 5000, intervalUnit: .minutes)
        let settings = editor.save()
        XCTAssertEqual(settings.shareLink, "https://adobe.ly/abc")
        XCTAssertEqual(editor.draft, settings, "the panel shows what was saved")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testChangingTheUnitKeepsTheNumberLegal() {
        var editor = SyncSettingsEditor(saved: saved)
        editor.draft.intervalValue = 200          // fine as minutes
        editor.setIntervalUnit(.days)             // but far past the cap for days
        XCTAssertEqual(editor.draft.intervalValue, IntervalUnit.days.range.upperBound)
        XCTAssertEqual(editor.draft.intervalUnit, .days)

        editor.setIntervalUnit(.hours)
        XCTAssertEqual(editor.draft.intervalValue, 30, "a legal number is left alone")
        XCTAssertEqual(editor.draft.checkInterval, 30 * 3600)
    }

    func testClearingTheLinkStopsTheLoop() {
        var editor = SyncSettingsEditor(saved: saved)
        editor.draft.shareLink = ""
        editor.save()
        XCTAssertFalse(editor.isReadyToSync)
        XCTAssertEqual(editor.saved?.isConfigured, false)
    }
}
