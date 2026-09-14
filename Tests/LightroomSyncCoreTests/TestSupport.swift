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

/// Minimal JPEG with an APP0 segment followed by a baseline SOF0 header.
func fakeJPEG(width: Int, height: Int) -> Data {
    func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
    var bytes: [UInt8] = [0xFF, 0xD8]
    let app0: [UInt8] = Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0]
    bytes += [0xFF, 0xE0] + be16(app0.count + 2) + app0
    let frame: [UInt8] = [8] + be16(height) + be16(width) + [3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]
    bytes += [0xFF, 0xC0] + be16(frame.count + 2) + frame
    bytes += [0xFF, 0xD9]
    return Data(bytes)
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

    func set(_ url: String, status: Int = 200, headers: [String: String] = [:], body: Data = Data(), finalURL: URL? = nil) {
        responses[url] = Canned(status: status, headers: headers, body: body, finalURL: finalURL)
    }

    func setJSON(_ url: String, _ json: String) {
        set(url, headers: ["content-type": "application/json"], body: Fixtures.guarded(json))
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        requests.append(url)
        lastHeaders = headers
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

    func importPhoto(_ request: PhotoImportRequest) async throws -> String {
        requests.append(request)
        if failNext {
            failNext = false
            throw NSError(domain: "FakeImporter", code: 7, userInfo: [NSLocalizedDescriptionKey: "simulated Photos failure"])
        }
        // Behave like PhotoKit with shouldMoveFile: the file is consumed.
        try? FileManager.default.removeItem(at: request.fileURL)
        identifiers += 1
        return "local-\(identifiers)"
    }
}

final class RecordingSink: SyncEventSink {
    var lines: [String] = []
    var progress: [(Int, Int)] = []

    func log(_ level: LogLevel, _ message: String) { lines.append("[\(level.rawValue)] \(message)") }
    func progress(completed: Int, total: Int) { progress.append((completed, total)) }
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
                cropped: (Int, Int) = (4000, 3000), subtype: String = "image", hasEdits: Bool = true) -> [String: Any] {
    var develop: [String: Any] = ["croppedWidth": cropped.0, "croppedHeight": cropped.1, "processingModel": "lightroom"]
    if hasEdits { develop["xmpCameraRaw"] = ["sha256": "abc"] }
    if let edited { develop["userUpdated"] = iso(edited) }
    var importSource: [String: Any] = ["fileName": fileName, "originalWidth": 4000, "originalHeight": 3000, "contentType": "image/jpeg"]
    if let sha { importSource["sha256"] = sha }
    let asset: [String: Any] = [
        "id": id, "type": "asset", "subtype": subtype,
        "created": iso(added), "updated": iso(edited ?? added),
        "payload": [
            "captureDate": "2024-05-01T10:20:30",
            "userCreated": iso(added), "userUpdated": iso(edited ?? added),
            "develop": develop, "importSource": importSource,
        ],
        "links": ["/rels/rendition_type/2048": ["href": "assets/\(id)/renditions/x"]],
    ]
    return [
        "id": id, "type": "album_asset", "created": iso(added), "updated": iso(edited ?? added),
        "payload": ["userCreated": iso(added), "userUpdated": iso(edited ?? added)],
        "asset": asset,
    ]
}
