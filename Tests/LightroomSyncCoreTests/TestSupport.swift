import Foundation
import XCTest
@testable import LightroomSyncCore

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return try Data(contentsOf: url)
    }

    /// Wraps a JSON body the way Lightroom serves it.
    static func guarded(_ json: String) -> Data {
        Data(("while (1) {}\n" + json).utf8)
    }
}

/// Minimal JPEG: an APP0 segment, whatever metadata segments were asked for, a baseline SOF0
/// header, a scan, and EOI.
///
/// `picture` seeds the scan's bytes, so two files stand for the same photograph only when it
/// matches — which is exactly what the content hash is there to tell apart. Photos in a test are
/// given distinct pictures for the same reason real ones have them.
func fakeJPEG(width: Int, height: Int, picture: String = "",
              metadata: [(marker: UInt8, payload: [UInt8])] = []) -> Data {
    func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    var bytes: [UInt8] = [0xFF, 0xD8]
    let app0: [UInt8] = Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0]
    bytes += [0xFF, 0xE0] + be16(app0.count + 2) + app0
    for segment in metadata {
        bytes += [0xFF, segment.marker] + be16(segment.payload.count + 2) + segment.payload
    }
    let frame: [UInt8] = [8] + be16(height) + be16(width) + [3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
    bytes += [0xFF, 0xC0] + be16(frame.count + 2) + frame
    let scanHeader: [UInt8] = [3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]
    bytes += [0xFF, 0xDA] + be16(scanHeader.count + 2) + scanHeader
    bytes += fakeScan(for: picture)
    bytes += [0xFF, 0xD9]
    return Data(bytes)
}

/// Stands in for the entropy-coded picture: bytes that differ per photograph, and that never look
/// like a marker, so a parser walking the file is not led off the end of the scan.
private func fakeScan(for picture: String) -> [UInt8] {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in picture.utf8 { value = (value ^ UInt64(byte)) &* 0x1000_0000_01b3 }
    return (0..<32).map { index in
        value = (value ^ UInt64(index)) &* 0x1000_0000_01b3
        return UInt8((value >> 24) & 0x7F)
    }
}

/// Canned HTTP responses keyed by absolute URL string.
final class FakeTransport: HTTPTransport {
    struct Canned {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        var finalURL: URL? = nil
    }

    var responses: [String: Canned] = [:]
    var requests: [URL] = []
    var lastHeaders: [String: String] = [:]
    /// Photos are fetched several at a time, so the recording below happens on several tasks at
    /// once. `responses` is only written during set-up, so only the recording needs guarding.
    private let lock = NSLock()

    func set(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data(), finalURL: URL? = nil) {
        responses[url] = Canned(status: status, headers: headers, body: body, finalURL: finalURL)
    }

    func setJSON(_ url: String, _ json: String) {
        set(url, headers: ["content-type": "application/json"], body: Fixtures.guarded(json))
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        lock.withLock {
            requests.append(url)
            lastHeaders = headers
        }
        guard let canned = responses[url.absoluteString] else {
            return HTTPResponse(status: 404, headers: [:], body: Data("not canned: \(url.absoluteString)".utf8), finalURL: url)
        }
        var lowered: [String: String] = [:]
        for (key, value) in canned.headers { lowered[key.lowercased()] = value }
        return HTTPResponse(status: canned.status, headers: lowered, body: canned.body, finalURL: canned.finalURL ?? url)
    }
}

final class FakeImporter: PhotoImporting {
    var requests: [PhotoImportRequest] = []
    var failNext = false
    var identifiers = 0
    /// Set so that importing files the photo into the library's album, as PhotoKit does.
    weak var library: FakePhotoLibrary?

    func importPhoto(_ request: PhotoImportRequest) async throws -> String {
        requests.append(request)
        if failNext {
            failNext = false
            throw NSError(domain: "FakeImporter", code: 7, userInfo: [NSLocalizedDescriptionKey: "simulated Photos failure"])
        }
        // Behave like PhotoKit with shouldMoveFile: the file is consumed.
        try? FileManager.default.removeItem(at: request.fileURL)
        identifiers += 1
        let identifier = "local-\(identifiers)"
        library?.imported(identifier, request: request)
        return identifier
    }
}

/// Stands in for ImageIO: writes a new, smaller file next to the one it was handed, the way the
/// real resizer does, and records every size it was asked for.
final class FakeResizer: PhotoResizing {
    var requests: [(url: URL, maxLongEdge: Int)] = []
    var error: Error?
    private let lock = NSLock()

    func resized(fileAt url: URL, maxLongEdge: Int) throws -> URL {
        lock.withLock { requests.append((url, maxLongEdge)) }
        if let error { throw error }
        guard let size = JPEGInfo.pixelSize(ofFileAt: url), size.longEdge > maxLongEdge else { return url }
        let scale = Double(maxLongEdge) / Double(size.longEdge)
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(maxLongEdge).jpg")
        try fakeJPEG(width: max(1, Int((Double(size.width) * scale).rounded())),
                     height: max(1, Int((Double(size.height) * scale).rounded())))
            .write(to: destination, options: .atomic)
        return destination
    }
}

/// Stands in for ImageIO: reports whatever the test says the downloaded file carries, and records
/// the metadata it was asked to write.
final class FakeMetadataWriter: PhotoMetadataWriting {
    /// What every file is said to already contain.
    var embedded = EmbeddedPhotoMetadata()
    var written: [PhotoMetadata] = []
    var error: Error?
    /// Set to write a new file next to the one handed over, the way the real writer does.
    var writesNewFile = false
    private let lock = NSLock()

    func embeddedMetadata(fileAt url: URL) -> EmbeddedPhotoMetadata { embedded }

    func write(_ metadata: PhotoMetadata, toFileAt url: URL) throws -> URL {
        lock.withLock { written.append(metadata) }
        if let error { throw error }
        guard writesNewFile else { return url }
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-described.jpg")
        try Data(contentsOf: url).write(to: destination, options: .atomic)
        return destination
    }
}

/// Stands in for the Photos library: which assets it holds and which album each one is in.
final class FakePhotoLibrary: PhotoLibraryAccess {
    /// Local identifiers keyed by the file name the library is asked about. Set up by a test to
    /// say the library already held a photo before the pass; matched on the name alone.
    var identifiers: [String: String] = [:]
    /// What importing put here, the way PhotoKit does: a photo is in the library from the moment
    /// it is imported, and the next lookup finds it. Matched the way the real library is searched,
    /// on the original file name and a capture date within the query's tolerance.
    private(set) var importedAssets: [(fileName: String, captureDate: Date?, identifier: String)] = []
    /// Album name to the identifiers currently in it.
    var albums: [String: Set<String>] = [:]
    /// Assets the user has deleted from the library outright.
    var deletedIdentifiers: Set<String> = []

    var queries: [PhotoMatchQuery] = []
    var albumExistsCalls: [String] = []
    var addCalls: [(identifiers: [String], album: String)] = []
    var error: Error?

    func findExistingAsset(matching query: PhotoMatchQuery) async throws -> String? {
        queries.append(query)
        if let error { throw error }
        if let identifier = identifiers[query.fileName] { return identifier }
        return importedAssets.first { asset in
            guard asset.fileName.caseInsensitiveCompare(query.fileName) == .orderedSame,
                  let captureDate = asset.captureDate else { return false }
            return abs(captureDate.timeIntervalSince(query.captureDate)) <= query.dateTolerance
        }?.identifier
    }

    func albumExists(named name: String) async throws -> Bool {
        albumExistsCalls.append(name)
        if let error { throw error }
        return albums[name] != nil
    }

    func addAssets(withIdentifiers identifiers: [String], toAlbumNamed name: String) async throws -> [String] {
        addCalls.append((identifiers, name))
        if let error { throw error }
        let live = identifiers.filter { !deletedIdentifiers.contains($0) }
        albums[name, default: []].formUnion(live)
        return live
    }

    /// What PhotoKit does when a photo is imported: the library holds it from then on, under the
    /// original file name and creation date it was imported with, and it is filed into the album.
    func imported(_ identifier: String, request: PhotoImportRequest) {
        if let fileName = request.originalFileName {
            importedAssets.append((fileName, request.captureDate, identifier))
        }
        file(identifier, inAlbum: request.albumName)
    }

    /// What PhotoKit does when a photo is imported with an album name.
    func file(_ identifier: String, inAlbum name: String?) {
        guard let name else { return }
        albums[name, default: []].insert(identifier)
    }
}

final class RecordingSink: SyncEventSink {
    var lines: [String] = []
    var progress: [(Int, Int)] = []
    var stages: [SyncStage] = []
    /// The protocol says these are called from arbitrary threads, and since photos are fetched
    /// several at a time they genuinely are.
    private let lock = NSLock()

    func log(_ level: LogLevel, _ message: String) {
        lock.withLock { lines.append("[\(level.rawValue)] \(message)") }
    }

    func progress(completed: Int, total: Int) {
        lock.withLock { progress.append((completed, total)) }
    }

    func stage(_ stage: SyncStage) {
        lock.withLock { stages.append(stage) }
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LightroomSyncTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

/// Builds an album-assets page in the gallery's JSON shape.
func assetsPageJSON(entries: [[String: Any]], next: String? = nil) -> String {
    var page: [String: Any] = ["base": "https://photos.adobe.io/v2/", "album": ["id": "album"], "resources": entries]
    if let next { page["links"] = ["next": ["href": next]] }
    let data = try! JSONSerialization.data(withJSONObject: page)
    return String(decoding: data, as: UTF8.self)
}

func assetEntry(id: String, fileName: String, sha: String? = nil, added: Date, edited: Date? = nil,
                cropped: (Int, Int) = (4000, 3000), subtype: String = "image", hasEdits: Bool = true,
                captureDate: String = "2024-05-01T10:20:30",
                extras: [String: Any] = [:]) -> [String: Any] {
    var develop: [String: Any] = ["croppedWidth": cropped.0, "croppedHeight": cropped.1, "processingModel": "lightroom"]
    if hasEdits { develop["xmpCameraRaw"] = ["sha256": "abc"] }
    if let edited { develop["userUpdated"] = iso(edited) }
    var importSource: [String: Any] = ["fileName": fileName, "originalWidth": 4000, "originalHeight": 3000, "contentType": "image/jpeg"]
    if let sha { importSource["sha256"] = sha }
    var payload: [String: Any] = [
        "captureDate": captureDate,
        "userCreated": iso(added), "userUpdated": iso(edited ?? added),
        "develop": develop, "importSource": importSource,
    ]
    payload.merge(extras) { _, extra in extra }
    let asset: [String: Any] = [
        "id": id, "type": "asset", "subtype": subtype,
        "created": iso(added), "updated": iso(edited ?? added),
        "payload": payload,
        "links": ["/rels/rendition_type/2048": ["href": "assets/\(id)/renditions/x"]],
    ]
    return [
        "id": id, "type": "album_asset", "created": iso(added), "updated": iso(edited ?? added),
        "payload": ["userCreated": iso(added), "userUpdated": iso(edited ?? added)],
        "asset": asset,
    ]
}
