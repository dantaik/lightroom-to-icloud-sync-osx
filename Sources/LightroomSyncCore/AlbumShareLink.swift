import Foundation

public enum AlbumShareLinkError: Error, LocalizedError, Equatable {
    case empty
    case unrecognized(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste the share link of a Lightroom album."
        case .unrecognized(let text):
            return "“\(text)” is not a Lightroom share link. Expected https://adobe.ly/… or https://lightroom.adobe.com/shares/…"
        }
    }
}

/// A Lightroom album share link as pasted by the user.
public struct AlbumShareLink: Equatable {
    public enum Kind: Equatable {
        /// A resolved `lightroom.adobe.com/shares/{shareID}` link, optionally pointing at one album.
        case share(shareID: String, albumID: String?)
        /// An `adobe.ly` short link that must be followed to find the share ID.
        case shortLink(URL)
    }

    public let kind: Kind
    public let original: String

    public init(kind: Kind, original: String) {
        self.kind = kind
        self.original = original
    }

    public static func parse(_ text: String) throws -> AlbumShareLink {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AlbumShareLinkError.empty }

        if isHexID(trimmed) {
            return AlbumShareLink(kind: .share(shareID: trimmed.lowercased(), albumID: nil), original: text)
        }

        var candidate = trimmed
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), let host = url.host?.lowercased() else {
            throw AlbumShareLinkError.unrecognized(trimmed)
        }
        let parts = url.pathComponents.filter { $0 != "/" }

        if host == "adobe.ly" || host == "www.adobe.ly" {
            guard let slug = parts.first, !slug.isEmpty else { throw AlbumShareLinkError.unrecognized(trimmed) }
            return AlbumShareLink(kind: .shortLink(url), original: text)
        }

        if host == "lightroom.adobe.com" || host == "www.lightroom.adobe.com" {
            if let index = parts.firstIndex(of: "shares"), index + 1 < parts.count, isHexID(parts[index + 1]) {
                var albumID: String?
                if let albumIndex = parts.firstIndex(of: "albums"), albumIndex + 1 < parts.count, isHexID(parts[albumIndex + 1]) {
                    albumID = parts[albumIndex + 1].lowercased()
                }
                return AlbumShareLink(kind: .share(shareID: parts[index + 1].lowercased(), albumID: albumID), original: text)
            }
        }

        throw AlbumShareLinkError.unrecognized(trimmed)
    }

    static func isHexID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isHexDigit }
    }
}
