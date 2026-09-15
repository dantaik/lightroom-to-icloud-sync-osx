import Foundation

public struct AlbumInfo: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let assetsHref: String?

    public init(id: String, name: String, assetsHref: String?) {
        self.id = id
        self.name = name
        self.assetsHref = assetsHref
    }
}

public struct ShareInfo: Equatable {
    public let shareID: String
    public let downloadsAllowed: Bool
    public let createdOnClient: String?
    public let albums: [AlbumInfo]

    public init(shareID: String, downloadsAllowed: Bool, createdOnClient: String?, albums: [AlbumInfo]) {
        self.shareID = shareID
        self.downloadsAllowed = downloadsAllowed
        self.createdOnClient = createdOnClient
        self.albums = albums
    }
}

public struct DownloadedPhoto: Equatable {
    public let fileURL: URL
    public let fileName: String?
    public let contentType: String?
    public let byteCount: Int
    /// How long this download spent waiting out a "slow down" from Adobe. Non-zero means the
    /// photos are being fetched faster than the share will serve them.
    public var throttleWait: Duration = .zero
}

public enum LightroomError: Error, LocalizedError, Equatable {
    case shortLinkUnresolved(URL)
    case httpStatus(Int, URL)
    case decoding(String, URL)
    case downloadsDisabled
    case unexpectedContentType(String?)
    case renditionUnavailable(String)
    case tooManyPages

    public var errorDescription: String? {
        switch self {
        case .shortLinkUnresolved(let url):
            return "Could not resolve \(url.absoluteString) to a Lightroom share."
        case .httpStatus(let status, let url):
            return "Lightroom returned HTTP \(status) for \(url.absoluteString)"
        case .decoding(let detail, let url):
            return "Unexpected response from \(url.absoluteString): \(detail)"
        case .downloadsDisabled:
            return "Downloads are disabled for this share. In Lightroom, open the album's share settings and turn on “Allow downloads”."
        case .unexpectedContentType(let type):
            return "Expected an image but received \(type ?? "no content type")."
        case .renditionUnavailable(let href):
            return "Lightroom listed a rendition at \(href), which is not a usable address."
        case .tooManyPages:
            return "The album listing did not end after 200 pages; giving up."
        }
    }
}

/// Client for the endpoints behind Lightroom's public web gallery (`lightroom.adobe.com/shares/…`).
///
/// These are the same unauthenticated calls the gallery page makes. They are not an official API.
public final class LightroomGalleryClient {
    public static let defaultUserAgent = "LightroomSync/0.1.0 (+https://github.com/dantaik/lightroom-to-icloud-sync-osx)"
    public static let apiBase = URL(string: "https://lightroom.adobe.com/v2c/")!
    public static let downloadBase = URL(string: "https://dl.lightroom.adobe.com/")!
    public static let pageSize = 500

    private let transport: HTTPTransport
    private let userAgent: String
    private let backoff: [Duration]

    public init(transport: HTTPTransport, userAgent: String = LightroomGalleryClient.defaultUserAgent,
                throttleBackoff: [Duration] = LightroomGalleryClient.throttleBackoff) {
        self.transport = transport
        self.userAgent = userAgent
        self.backoff = throttleBackoff
    }

    /// Turns a pasted link into a share ID (following `adobe.ly` redirects when needed).
    public func resolve(_ link: AlbumShareLink) async throws -> (shareID: String, albumID: String?) {
        switch link.kind {
        case .share(let shareID, let albumID):
            return (shareID, albumID)
        case .shortLink(let url):
            let response = try await transport.get(url, headers: ["User-Agent": userAgent])
            guard let finalURL = response.finalURL,
                  let resolved = try? AlbumShareLink.parse(finalURL.absoluteString),
                  case .share(let shareID, let albumID) = resolved.kind
            else { throw LightroomError.shortLinkUnresolved(url) }
            return (shareID, albumID)
        }
    }

    public func fetchShare(shareID: String) async throws -> ShareInfo {
        let space: SpaceResponse = try await getJSON(url("spaces/\(shareID)"))
        let resources: ResourcesResponse = try await getJSON(url("spaces/\(shareID)/resources"))
        let albums = resources.resources
            .filter { $0.type == "album" }
            .map { AlbumInfo(id: $0.id, name: $0.payload?.name ?? "Untitled album",
                             assetsHref: $0.links?["/rels/space_album_images_videos"]) }
        return ShareInfo(shareID: shareID,
                         downloadsAllowed: space.payload?.download ?? false,
                         createdOnClient: space.createdOnClient,
                         albums: albums)
    }

    /// Lists every asset of an album, following pagination links.
    public func listPhotos(shareID: String, albumID: String) async throws -> [LightroomPhoto] {
        let spaceBase = url("spaces/\(shareID)/")
        var pageURL = URL(string: "albums/\(albumID)/assets?embed=asset&subtype=image%3Bvideo&limit=\(Self.pageSize)",
                          relativeTo: spaceBase)!.absoluteURL
        var photos: [LightroomPhoto] = []
        var pages = 0
        while true {
            pages += 1
            guard pages <= 200 else { throw LightroomError.tooManyPages }
            let page: AlbumAssetsPage = try await getJSON(pageURL)
            photos.append(contentsOf: page.resources.compactMap(LightroomPhoto.init(entry:)))
            guard let next = page.links?["next"],
                  let nextURL = URL(string: next, relativeTo: spaceBase)?.absoluteURL
            else { break }
            pageURL = nextURL
        }
        return photos
    }

    /// Downloads the full-size edited rendition of a photo (what the gallery's Download button serves).
    ///
    /// Lightroom builds this file on demand, so it is by far the slowest call the app makes.
    public func downloadFullSize(shareID: String, assetID: String, to directory: URL) async throws -> DownloadedPhoto {
        let downloadURL = URL(string: "spaces/\(shareID)/assets/\(assetID)", relativeTo: Self.downloadBase)!.absoluteURL
        do {
            return try await downloadImage(at: downloadURL, assetID: assetID, to: directory)
        } catch LightroomError.httpStatus(403, _) {
            // The download host answers 403 for exactly one reason: the share forbids downloads.
            throw LightroomError.downloadsDisabled
        }
    }

    /// Downloads a rendition Lightroom already holds, named by one of the asset's
    /// `/rels/rendition_type/…` links. Nothing is rendered on demand, so this returns in a
    /// fraction of the time the full-size download takes.
    ///
    /// The href is relative to `spaces/{shareID}/`, the same base the album listing came from.
    public func downloadRendition(shareID: String, assetID: String, href: String, to directory: URL) async throws -> DownloadedPhoto {
        let base = url("spaces/\(shareID)/")
        guard let renditionURL = URL(string: href, relativeTo: base)?.absoluteURL else {
            throw LightroomError.renditionUnavailable(href)
        }
        return try await downloadImage(at: renditionURL, assetID: assetID, to: directory)
    }

    /// How long to wait before asking again after being told to slow down, once per attempt.
    /// Photos are fetched several at a time, so a burst can be throttled rather than refused, and
    /// waiting it out is the difference between a slower pass and a pass full of failed photos.
    public static let throttleBackoff: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]
    static let throttleStatuses: Set<Int> = [429, 503]

    /// The part both downloads share: fetch, check that it really is an image, write it out.
    private func downloadImage(at url: URL, assetID: String, to directory: URL) async throws -> DownloadedPhoto {
        var attempt = 0
        var waited = Duration.zero
        var response: HTTPResponse
        while true {
            response = try await transport.get(url, headers: [
                "User-Agent": userAgent,
                "Accept": "image/jpeg,image/*;q=0.9,*/*;q=0.5",
            ])
            guard Self.throttleStatuses.contains(response.status), attempt < backoff.count
            else { break }
            let wait = Self.retryAfter(response.header("retry-after")) ?? backoff[attempt]
            try await Task.sleep(for: wait)
            waited += wait
            attempt += 1
        }
        guard response.status == 200 else { throw LightroomError.httpStatus(response.status, url) }
        let contentType = response.header("content-type")
        guard let contentType, contentType.lowercased().hasPrefix("image/") else {
            throw LightroomError.unexpectedContentType(contentType)
        }
        let fileName = Self.fileName(fromContentDisposition: response.header("content-disposition"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(assetID).\(Self.fileExtension(for: contentType))")
        try response.body.write(to: fileURL, options: .atomic)
        return DownloadedPhoto(fileURL: fileURL, fileName: fileName, contentType: contentType,
                               byteCount: response.body.count, throttleWait: waited)
    }

    // MARK: - Helpers

    /// `Retry-After: 30`, in seconds, when the server names a wait of its own. The HTTP-date form
    /// is ignored and anything beyond two minutes is refused: a wait that long is worse for the
    /// pass than the backoff already in hand.
    static func retryAfter(_ header: String?) -> Duration? {
        guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)),
              seconds > 0, seconds <= 120
        else { return nil }
        return .seconds(seconds)
    }

    static func fileExtension(for contentType: String) -> String {
        switch contentType.lowercased().split(separator: ";").first.map(String.init) ?? "" {
        case "image/png": return "png"
        case "image/heic", "image/heif": return "heic"
        case "image/tiff": return "tif"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }

    /// Extracts the file name from `attachment; filename*=utf-8''Name.jpg` or `filename="Name.jpg"`.
    static func fileName(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        let pieces = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for piece in pieces where piece.lowercased().hasPrefix("filename*=") {
            var value = String(piece.dropFirst("filename*=".count))
            if let marker = value.range(of: "''") { value = String(value[marker.upperBound...]) }
            let decoded = value.removingPercentEncoding ?? value
            return decoded.isEmpty ? nil : decoded
        }
        for piece in pieces where piece.lowercased().hasPrefix("filename=") {
            let value = String(piece.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: Self.apiBase)!.absoluteURL
    }

    private func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        let response = try await transport.get(url, headers: ["User-Agent": userAgent, "Accept": "application/json"])
        guard response.status == 200 else { throw LightroomError.httpStatus(response.status, url) }
        do {
            return try AdobeJSON.decode(T.self, from: response.body)
        } catch {
            throw LightroomError.decoding(String(describing: error), url)
        }
    }
}
