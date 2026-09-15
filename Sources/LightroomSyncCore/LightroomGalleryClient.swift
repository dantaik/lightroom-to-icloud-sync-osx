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
    /// How many times the connection under this download failed and it had to be started again.
    public var transportRetries: Int = 0
    /// How long this download spent waiting out those failed connections.
    public var retryWait: Duration = .zero
    /// True when at least one of those restarts picked the transfer up where it stopped rather
    /// than fetching it from the beginning again.
    public var resumed: Bool = false
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
    private let transportBackoff: [Duration]

    public init(transport: HTTPTransport, userAgent: String = LightroomGalleryClient.defaultUserAgent,
                throttleBackoff: [Duration] = LightroomGalleryClient.throttleBackoff,
                transportBackoff: [Duration] = LightroomGalleryClient.transportBackoff) {
        self.transport = transport
        self.userAgent = userAgent
        self.backoff = throttleBackoff
        self.transportBackoff = transportBackoff
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

    /// How long to wait before starting a download again after the connection under it failed,
    /// once per attempt.
    ///
    /// Longer and more patient than ``throttleBackoff``, because it is waiting out something
    /// else entirely. A throttle is Adobe answering; this is nothing answering at all, and the
    /// causes — a Wi-Fi handover, a VPN reconnecting, a router dropping a long-lived transfer —
    /// take a minute or two to pass rather than seconds. The ladder covers about three and a
    /// half minutes in total, which is what a real outage on this app cost: nine photos and
    /// roughly eighty minutes of Adobe's rendering, thrown away because nothing tried again.
    public static let transportBackoff: [Duration] = [.seconds(5), .seconds(20), .seconds(60), .seconds(120)]

    /// Whether a transfer that failed outright is worth starting again.
    ///
    /// Only the failures that pass on their own. A refused or malformed request would fail the
    /// same way every time, and cancellation is the app being stopped — retrying either would
    /// turn a quick failure into a slow one.
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError { return retryableCodes.contains(urlError.code.rawValue) }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return retryableCodes.contains(nsError.code)
    }

    /// URLSession codes worth another attempt. `NSURLErrorCancelled` is deliberately absent: that
    /// is the app stopping the pass, not the network failing.
    static let retryableCodes: Set<Int> = [
        // The one that ended nine downloads in the same second on a real album.
        URLError.Code.networkConnectionLost.rawValue,
        URLError.Code.timedOut.rawValue,
        URLError.Code.cannotConnectToHost.rawValue,
        URLError.Code.cannotFindHost.rawValue,
        URLError.Code.dnsLookupFailed.rawValue,
        URLError.Code.notConnectedToInternet.rawValue,
        URLError.Code.secureConnectionFailed.rawValue,
        URLError.Code.badServerResponse.rawValue,
    ]

    /// What one transfer cost beyond the bytes: the waiting, and whether any of it was salvaged.
    private struct TransferAttempt {
        var response: HTTPFileResponse
        var retries = 0
        var retryWait = Duration.zero
        var resumed = false
    }

    /// The part both downloads share: fetch, check that it really is an image, name it.
    ///
    /// The body streams to a `.part` file, because the extension it ends up with depends on the
    /// content type and that is not known until the response arrives.
    private func downloadImage(at url: URL, assetID: String, to directory: URL) async throws -> DownloadedPhoto {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partURL = directory.appendingPathComponent("\(assetID).part")
        // Nothing may be left behind on a path out of here. A successful download is moved off
        // this name, so by then there is nothing to remove; every other path — a throttle loop
        // whose next attempt throws, a body that turns out not to be an image — would otherwise
        // strand a part-finished file for the next pass's sweep to find.
        defer { try? FileManager.default.removeItem(at: partURL) }

        var attempt = try await transfer(url, to: partURL)
        var retries = attempt.retries
        var retryWait = attempt.retryWait
        var resumed = attempt.resumed
        var throttleWait = Duration.zero
        var throttleAttempt = 0
        // A throttled response is Adobe declining to serve this yet, so the wait is followed by
        // asking again from the start; there is nothing part-finished to resume.
        while Self.throttleStatuses.contains(attempt.response.status), throttleAttempt < backoff.count {
            let wait = Self.retryAfter(attempt.response.header("retry-after")) ?? backoff[throttleAttempt]
            try await Task.sleep(for: wait)
            throttleWait += wait
            throttleAttempt += 1
            attempt = try await transfer(url, to: partURL)
            retries += attempt.retries
            retryWait += attempt.retryWait
            resumed = resumed || attempt.resumed
        }

        let response = attempt.response
        guard response.status == 200, let downloadedURL = response.fileURL else {
            try? FileManager.default.removeItem(at: partURL)
            throw LightroomError.httpStatus(response.status, url)
        }
        let contentType = response.header("content-type")
        guard let contentType, contentType.lowercased().hasPrefix("image/") else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw LightroomError.unexpectedContentType(contentType)
        }
        let fileName = Self.fileName(fromContentDisposition: response.header("content-disposition"))
        let fileURL = directory.appendingPathComponent("\(assetID).\(Self.fileExtension(for: contentType))")
        if downloadedURL != fileURL {
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: downloadedURL, to: fileURL)
        }
        return DownloadedPhoto(fileURL: fileURL, fileName: fileName, contentType: contentType,
                               byteCount: response.byteCount, throttleWait: throttleWait,
                               transportRetries: retries, retryWait: retryWait, resumed: resumed)
    }

    /// One transfer, started again when the connection under it fails.
    ///
    /// Picks up where the failed one stopped when the server left enough state to do so, and
    /// starts over when it did not. Either way the render Adobe has already done is worth far
    /// more than the seconds spent waiting here.
    private func transfer(_ url: URL, to fileURL: URL) async throws -> TransferAttempt {
        var resumeData: Data?
        var attempt = 0
        var retryWait = Duration.zero
        while true {
            do {
                let response = try await transport.download(url, headers: [
                    "User-Agent": userAgent,
                    "Accept": "image/jpeg,image/*;q=0.9,*/*;q=0.5",
                ], to: fileURL, resuming: resumeData)
                return TransferAttempt(response: response, retries: attempt,
                                       retryWait: retryWait, resumed: response.resumed)
            } catch {
                // `ResumableDownloadError` is only a wrapper carrying what a second attempt would
                // need; what the caller should see, and what decides retryability, is inside it.
                let resumable = error as? ResumableDownloadError
                let underlying = resumable?.underlying ?? error
                guard Self.isRetryable(underlying), attempt < transportBackoff.count else { throw underlying }
                try Task.checkCancellation()
                let wait = transportBackoff[attempt]
                try await Task.sleep(for: wait)
                retryWait += wait
                attempt += 1
                resumeData = resumable?.resumeData
            }
        }
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
