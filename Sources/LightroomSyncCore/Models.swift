import Foundation

// MARK: - Wire format (lenient Decodable models for the gallery JSON)

/// A map of link relations to hrefs. Values that are not `{"href": ...}` objects are ignored.
public struct LinkMap: Decodable, Equatable {
    public let hrefs: [String: String]

    public init(hrefs: [String: String]) {
        self.hrefs = hrefs
    }

    public subscript(rel: String) -> String? { hrefs[rel] }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private struct Link: Decodable {
        let href: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var hrefs: [String: String] = [:]
        for key in container.allKeys {
            if let link = try? container.decode(Link.self, forKey: key) {
                hrefs[key.stringValue] = link.href
            }
        }
        self.hrefs = hrefs
    }
}

/// `GET /v2c/spaces/{shareID}`
public struct SpaceResponse: Decodable {
    public struct Payload: Decodable {
        public let download: Bool?
        public let isPrivate: Bool?

        enum CodingKeys: String, CodingKey {
            case download
            case isPrivate = "private"
        }
    }

    public let id: String
    public let subtype: String?
    public let createdOnClient: String?
    public let payload: Payload?
}

/// `GET /v2c/spaces/{shareID}/resources`
public struct ResourcesResponse: Decodable {
    public let resources: [SpaceResource]
}

public struct SpaceResource: Decodable {
    public struct Payload: Decodable {
        public let name: String?
    }

    public let id: String
    public let type: String
    public let subtype: String?
    public let payload: Payload?
    public let links: LinkMap?
}

/// One page of `GET /v2c/spaces/{shareID}/albums/{albumID}/assets?embed=asset`
public struct AlbumAssetsPage: Decodable {
    public let resources: [AlbumAssetEntry]
    public let links: LinkMap?
}

public struct AlbumAssetEntry: Decodable {
    public struct Payload: Decodable {
        public let userCreated: String?
        public let userUpdated: String?
    }

    public let id: String
    public let created: String?
    public let updated: String?
    public let payload: Payload?
    public let asset: LightroomAsset?
}

public struct LightroomAsset: Decodable {
    public struct Payload: Decodable {
        public let captureDate: String?
        public let userCreated: String?
        public let userUpdated: String?
        public let develop: Develop?
        public let importSource: ImportSource?
    }

    public struct Develop: Decodable {
        public let croppedWidth: Int?
        public let croppedHeight: Int?
        public let userUpdated: String?
        /// True when the asset carries Camera Raw develop settings, i.e. it has been edited.
        public let hasCameraRawSettings: Bool

        enum CodingKeys: String, CodingKey {
            case croppedWidth, croppedHeight, userUpdated, xmpCameraRaw
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            croppedWidth = Self.lenientInt(container, .croppedWidth)
            croppedHeight = Self.lenientInt(container, .croppedHeight)
            userUpdated = (try? container.decodeIfPresent(String.self, forKey: .userUpdated)) ?? nil
            hasCameraRawSettings = container.contains(.xmpCameraRaw)
        }

        private static func lenientInt(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
            return nil
        }
    }

    public struct ImportSource: Decodable {
        public let fileName: String?
        public let originalWidth: Int?
        public let originalHeight: Int?
        public let contentType: String?
        public let sha256: String?
    }

    public let id: String
    public let subtype: String?
    public let created: String?
    public let updated: String?
    public let payload: Payload?
}

// MARK: - Domain model

/// A photo in a shared Lightroom album, normalized from the wire format.
public struct LightroomPhoto: Equatable, Identifiable {
    public var id: String { assetID }

    public let assetID: String
    public let subtype: String
    public let fileName: String?
    public let originalSHA256: String?
    public let originalWidth: Int?
    public let originalHeight: Int?
    public let croppedWidth: Int?
    public let croppedHeight: Int?
    public let captureDate: Date?
    /// When the photo was added to the shared album (best effort from Lightroom's timestamps).
    public let addedToAlbumAt: Date?
    /// The most recent edit or metadata change Lightroom reports for the photo.
    public let lastEditedAt: Date?
    public let hasEdits: Bool

    public init(assetID: String, subtype: String, fileName: String?, originalSHA256: String?,
                originalWidth: Int?, originalHeight: Int?, croppedWidth: Int?, croppedHeight: Int?,
                captureDate: Date?, addedToAlbumAt: Date?, lastEditedAt: Date?, hasEdits: Bool) {
        self.assetID = assetID
        self.subtype = subtype
        self.fileName = fileName
        self.originalSHA256 = originalSHA256
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.croppedWidth = croppedWidth
        self.croppedHeight = croppedHeight
        self.captureDate = captureDate
        self.addedToAlbumAt = addedToAlbumAt
        self.lastEditedAt = lastEditedAt
        self.hasEdits = hasEdits
    }

    public init?(entry: AlbumAssetEntry) {
        guard let asset = entry.asset else { return nil }
        let payload = asset.payload
        // Only user-driven timestamps count as edits. The asset's generic `updated` field also moves
        // when Adobe touches the record (renditions, aesthetics), which must not delay a sync.
        let edits = [payload?.develop?.userUpdated, payload?.userUpdated]
            .compactMap { AdobeDate.parse($0) }
        self.init(
            assetID: asset.id,
            subtype: asset.subtype ?? "unknown",
            fileName: payload?.importSource?.fileName,
            originalSHA256: payload?.importSource?.sha256,
            originalWidth: payload?.importSource?.originalWidth,
            originalHeight: payload?.importSource?.originalHeight,
            croppedWidth: payload?.develop?.croppedWidth,
            croppedHeight: payload?.develop?.croppedHeight,
            captureDate: AdobeDate.parse(payload?.captureDate),
            addedToAlbumAt: AdobeDate.parse(entry.payload?.userCreated)
                ?? AdobeDate.parse(entry.created)
                ?? AdobeDate.parse(payload?.userCreated)
                ?? AdobeDate.parse(asset.created),
            lastEditedAt: edits.max(),
            hasEdits: payload?.develop?.hasCameraRawSettings ?? false
        )
    }

    public var isImage: Bool { subtype == "image" }

    /// Long edge of the edited (cropped) photo, when Lightroom reports it.
    public var expectedLongEdge: Int? {
        guard let width = croppedWidth, let height = croppedHeight else { return nil }
        return max(width, height)
    }
}
