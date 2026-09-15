import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse {
    public let status: Int
    /// Header names are lowercased.
    public let headers: [String: String]
    public let body: Data
    /// The URL that finally served the response, after redirects.
    public let finalURL: URL?

    public init(status: Int, headers: [String: String], body: Data, finalURL: URL?) {
        self.status = status
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// A response whose body went straight to a file instead of being held in memory.
///
/// A full-size Lightroom render is tens of megabytes and several are fetched at once, so the
/// difference between this and ``HTTPResponse`` is the difference between a few hundred megabytes
/// of resident memory and none.
public struct HTTPFileResponse {
    public let status: Int
    /// Header names are lowercased.
    public let headers: [String: String]
    /// Where the body landed. Nil when the status says there was no body worth keeping.
    public let fileURL: URL?
    public let byteCount: Int
    /// The URL that finally served the response, after redirects.
    public let finalURL: URL?
    /// True when this transfer picked up where a failed one stopped rather than starting over.
    public let resumed: Bool

    public init(status: Int, headers: [String: String], fileURL: URL?, byteCount: Int,
                finalURL: URL?, resumed: Bool = false) {
        self.status = status
        self.headers = headers
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.finalURL = finalURL
        self.resumed = resumed
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public enum TransportError: Error, LocalizedError {
    case notHTTP(URL)

    public var errorDescription: String? {
        switch self {
        case .notHTTP(let url): return "Unexpected non-HTTP response from \(url.absoluteString)"
        }
    }
}

/// A failed transfer that left behind enough state to pick it up where it stopped.
///
/// The caller decides whether to try again; this only carries what a second attempt would need.
/// `resumeData` is nil whenever the server does not support ranged requests, in which case a
/// retry starts the transfer over.
public struct ResumableDownloadError: Error, LocalizedError {
    public let underlying: Error
    public let resumeData: Data?

    public init(underlying: Error, resumeData: Data?) {
        self.underlying = underlying
        self.resumeData = resumeData
    }

    public var errorDescription: String? { underlying.localizedDescription }
}

/// Minimal HTTP abstraction so the client can be tested without a network.
public protocol HTTPTransport {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
    /// Streams a response body to `fileURL` rather than into memory.
    ///
    /// `resuming` is resume data from an earlier ``ResumableDownloadError``, when the caller is
    /// retrying a transfer that died partway. A transport that cannot resume ignores it.
    func download(_ url: URL, headers: [String: String], to fileURL: URL, resuming: Data?) async throws -> HTTPFileResponse
}

public extension HTTPTransport {
    /// For transports that only know how to answer in memory — the fakes in the tests, and
    /// platforms whose URLSession has no streaming download. Resume data is meaningless here, so
    /// a retry starts over.
    func download(_ url: URL, headers: [String: String], to fileURL: URL, resuming: Data?) async throws -> HTTPFileResponse {
        let response = try await get(url, headers: headers)
        guard response.status == 200 else {
            return HTTPFileResponse(status: response.status, headers: response.headers, fileURL: nil,
                                    byteCount: 0, finalURL: response.finalURL)
        }
        try response.body.write(to: fileURL, options: .atomic)
        return HTTPFileResponse(status: response.status, headers: response.headers, fileURL: fileURL,
                                byteCount: response.body.count, finalURL: response.finalURL)
    }
}

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// How long a single download may take from start to finish.
    ///
    /// Lightroom renders the full-size file on demand, so the clock covers the render as well as
    /// the transfer. This used to be fifteen minutes, which a 60 MP raw came within eighty
    /// seconds of on a real album; an hour leaves the ceiling well clear of the work.
    public static let resourceTimeout: TimeInterval = 60 * 60
    /// How long a download may go without a single byte arriving before it is given up on.
    /// A stalled transfer is caught by this rather than by ``resourceTimeout``.
    public static let requestTimeout: TimeInterval = 60

    /// - Parameter maximumConnectionsPerHost: how many connections may be open to Adobe at once.
    ///   URLSession's own default is 6, which silently queued photos seven and eight of a
    ///   "fetch 8 at once" pass — they sat waiting for a connection while their timing clock ran,
    ///   and looked like slow downloads rather than queued ones.
    public init(session: URLSession? = nil, maximumConnectionsPerHost: Int = SyncSettings.downloadConcurrencyRange.upperBound) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.resourceTimeout
            configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
            #if !canImport(FoundationNetworking)
            configuration.waitsForConnectivity = true
            #endif
            self.session = URLSession(configuration: configuration)
        }
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: Self.request(url, headers: headers))
        guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP(url) }
        return HTTPResponse(status: http.statusCode, headers: Self.lowercased(http.allHeaderFields),
                            body: data, finalURL: http.url)
    }

    public func download(_ url: URL, headers: [String: String], to fileURL: URL, resuming: Data?) async throws -> HTTPFileResponse {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no streaming download task. Linux only ever runs the
        // tests, which use their own transport, so buffering here costs nothing real.
        return try await downloadBuffered(url, headers: headers, to: fileURL)
        #else
        let temporaryURL: URL
        let response: URLResponse
        let resumed: Bool
        do {
            if let resuming {
                (temporaryURL, response) = try await session.download(resumeFrom: resuming)
                resumed = true
            } else {
                (temporaryURL, response) = try await session.download(for: Self.request(url, headers: headers))
                resumed = false
            }
        } catch {
            // What a second attempt would need to avoid starting the transfer over. Present only
            // when the server supports ranged requests; absent, the retry re-fetches from zero.
            throw ResumableDownloadError(underlying: error,
                                         resumeData: (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw TransportError.notHTTP(url)
        }
        let headers = Self.lowercased(http.allHeaderFields)
        guard http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            return HTTPFileResponse(status: http.statusCode, headers: headers, fileURL: nil,
                                    byteCount: 0, finalURL: http.url)
        }
        // URLSession deletes its temporary file the moment this call returns, so it has to be
        // moved rather than read.
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        return HTTPFileResponse(status: http.statusCode, headers: headers, fileURL: fileURL,
                                byteCount: byteCount ?? 0, finalURL: http.url, resumed: resumed)
        #endif
    }

    /// The in-memory path, for platforms with no streaming download task.
    private func downloadBuffered(_ url: URL, headers: [String: String], to fileURL: URL) async throws -> HTTPFileResponse {
        let response = try await get(url, headers: headers)
        guard response.status == 200 else {
            return HTTPFileResponse(status: response.status, headers: response.headers, fileURL: nil,
                                    byteCount: 0, finalURL: response.finalURL)
        }
        try response.body.write(to: fileURL, options: .atomic)
        return HTTPFileResponse(status: response.status, headers: response.headers, fileURL: fileURL,
                                byteCount: response.body.count, finalURL: response.finalURL)
    }

    private static func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private static func lowercased(_ fields: [AnyHashable: Any]) -> [String: String] {
        var lowered: [String: String] = [:]
        for (key, value) in fields {
            if let name = key as? String, let text = value as? String {
                lowered[name.lowercased()] = text
            }
        }
        return lowered
    }
}
