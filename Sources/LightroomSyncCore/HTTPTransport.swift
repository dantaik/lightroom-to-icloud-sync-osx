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

public enum TransportError: Error, LocalizedError {
    case notHTTP(URL)

    public var errorDescription: String? {
        switch self {
        case .notHTTP(let url): return "Unexpected non-HTTP response from \(url.absoluteString)"
        }
    }
}

/// Minimal HTTP abstraction so the client can be tested without a network.
public protocol HTTPTransport {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 15 * 60
            #if !canImport(FoundationNetworking)
            configuration.waitsForConnectivity = true
            #endif
            self.session = URLSession(configuration: configuration)
        }
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP(url) }
        var lowered: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let text = value as? String {
                lowered[name.lowercased()] = text
            }
        }
        return HTTPResponse(status: http.statusCode, headers: lowered, body: data, finalURL: http.url)
    }
}
