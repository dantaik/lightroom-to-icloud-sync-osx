import XCTest
@testable import LightroomSyncCore

final class SyncSettingsTests: XCTestCase {
    private func settings(link: String = "https://adobe.ly/abc", album: String? = nil,
                          photos: String = "Lightroom", minutes: Int = 15) -> SyncSettings {
        SyncSettings(shareLink: link, albumID: album, photosAlbumName: photos, intervalMinutes: minutes)
    }

    func testNormalizationTrimsAndClamps() {
        let messy = SyncSettings(shareLink: "  https://adobe.ly/abc\n", albumID: "",
                                 photosAlbumName: " Lightroom ", intervalMinutes: 99_999)
        let clean = messy.normalized
        XCTAssertEqual(clean.shareLink, "https://adobe.ly/abc")
        XCTAssertNil(clean.albumID)
        XCTAssertEqual(clean.photosAlbumName, "Lightroom")
        XCTAssertEqual(clean.intervalMinutes, SyncSettings.intervalRange.upperBound)
        XCTAssertEqual(SyncSettings(shareLink: "x", albumID: nil, photosAlbumName: "", intervalMinutes: 0).normalized.intervalMinutes,
                       SyncSettings.intervalRange.lowerBound)
        XCTAssertEqual(clean.normalized, clean, "normalizing twice changes nothing")
    }

    func testIsConfiguredNeedsAShareLink() {
        XCTAssertFalse(SyncSettings.empty.isConfigured)
        XCTAssertFalse(settings(link: "   ").isConfigured)
        XCTAssertTrue(settings().isConfigured)
    }

    func testSyncConfigurationUsesTheNormalizedValues() {
        let configuration = settings(album: "album-1", photos: "  Lightroom  ", minutes: 30)
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
                                     photosAlbumName: "Lightroom", intervalMinutes: 15)

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
        editor.draft.intervalMinutes = 600
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
                                    photosAlbumName: " Trips ", intervalMinutes: 5000)
        let settings = editor.save()
        XCTAssertEqual(settings.shareLink, "https://adobe.ly/abc")
        XCTAssertEqual(editor.draft, settings, "the panel shows what was saved")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testClearingTheLinkStopsTheLoop() {
        var editor = SyncSettingsEditor(saved: saved)
        editor.draft.shareLink = ""
        editor.save()
        XCTAssertFalse(editor.isReadyToSync)
        XCTAssertEqual(editor.saved?.isConfigured, false)
    }
}
