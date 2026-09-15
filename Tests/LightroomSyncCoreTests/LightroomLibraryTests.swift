import XCTest
@testable import LightroomSyncCore

final class LightroomLibraryTests: XCTestCase {
    /// Builds a stand-in for `Lightroom Library.lrlibrary` with the directories the real one has.
    private func makeLibrary(previewLongEdges: [Int] = [], originals: Int = 0,
                             inHome home: URL? = nil) throws -> URL {
        let base = try home ?? makeTemporaryDirectory()
        let library = base.appendingPathComponent(LightroomLibrary.defaultRelativePath)
        let previews = library.appendingPathComponent("previews.noindex")
        let manager = FileManager.default
        try manager.createDirectory(at: previews, withIntermediateDirectories: true)
        // The real package nests previews under a fan-out of short directories, so the walk has
        // to recurse rather than list one level.
        for (index, longEdge) in previewLongEdges.enumerated() {
            let nested = previews.appendingPathComponent("\(index % 3)/\(index % 5)", isDirectory: true)
            try manager.createDirectory(at: nested, withIntermediateDirectories: true)
            try fakeJPEG(width: longEdge, height: longEdge * 2 / 3, picture: "preview-\(index)")
                .write(to: nested.appendingPathComponent("p\(index).jpg"), options: .atomic)
        }
        if originals > 0 {
            let folder = library.appendingPathComponent("originals/a", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<originals {
                // Raw files, deliberately not readable as JPEGs — the point of the distinction.
                try Data(repeating: 0x42, count: 2048)
                    .write(to: folder.appendingPathComponent("L100\(index).DNG"), options: .atomic)
            }
        }
        return library
    }

    func testLocatesTheLibraryInAHomeDirectory() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(LightroomLibrary.locate(inHome: home), "nothing there yet")
        _ = try makeLibrary(previewLongEdges: [1024], inHome: home)
        XCTAssertEqual(LightroomLibrary.locate(inHome: home)?.lastPathComponent, "Lightroom Library.lrlibrary")
    }

    func testMeasuresPreviewsRecursivelyAndReportsTheirSizes() throws {
        let library = try makeLibrary(previewLongEdges: [640, 1280, 2560, 2560, 640])
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent().deletingLastPathComponent()) }

        let report = try LightroomLibrary.survey(library)
        let previews = try XCTUnwrap(report.folder("previews.noindex"))
        XCTAssertEqual(previews.fileCount, 5)
        XCTAssertEqual(previews.sampledLongEdges, [640, 640, 1280, 2560, 2560])
        XCTAssertEqual(previews.extensions["jpg"], 5)
        XCTAssertEqual(report.largestPreviewLongEdge, 2560)
        XCTAssertGreaterThan(report.totalBytes, 0)
    }

    /// The finding that decides whether any of this is worth doing: Lightroom's renders are built
    /// for the screen, so against a 6016 px setting they cover nothing.
    func testPreviewsTooSmallForTheChosenSizeServeNothing() throws {
        let library = try makeLibrary(previewLongEdges: [640, 1280, 2560])
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent().deletingLastPathComponent()) }

        let report = try LightroomLibrary.survey(library)
        XCTAssertEqual(report.servablePhotoSizes, [.small], "2560 px covers Small (2048) and nothing above it")
        XCTAssertFalse(report.servablePhotoSizes.contains(.large))
        XCTAssertFalse(report.servablePhotoSizes.contains(.medium))
        XCTAssertFalse(report.servablePhotoSizes.contains(.original), "“Original” is never servable from a cache")
    }

    func testLargeRendersWouldCoverEveryCappedSize() throws {
        let library = try makeLibrary(previewLongEdges: [6016])
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent().deletingLastPathComponent()) }

        let report = try LightroomLibrary.survey(library)
        XCTAssertEqual(Set(report.servablePhotoSizes), [.small, .medium, .large])
        XCTAssertFalse(report.servablePhotoSizes.contains(.original))
    }

    func testOriginalsAreCountedButNeverMeasuredAsRenders() throws {
        let library = try makeLibrary(previewLongEdges: [1280], originals: 4)
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent().deletingLastPathComponent()) }

        let report = try LightroomLibrary.survey(library)
        let originals = try XCTUnwrap(report.folder("originals"))
        XCTAssertEqual(originals.fileCount, 4)
        XCTAssertEqual(originals.extensions["dng"], 4)
        XCTAssertTrue(originals.sampledLongEdges.isEmpty, "raw files are not renders and must not be counted as any")
        // Originals must never widen what the library can serve.
        XCTAssertEqual(report.largestPreviewLongEdge, 1280)
    }

    func testAnEmptyLibraryServesNothing() throws {
        let library = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent().deletingLastPathComponent()) }

        let report = try LightroomLibrary.survey(library)
        XCTAssertNil(report.largestPreviewLongEdge)
        XCTAssertEqual(report.servablePhotoSizes, [])
    }
}
