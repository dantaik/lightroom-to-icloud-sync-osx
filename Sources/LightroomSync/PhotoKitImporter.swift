#if os(macOS)
import CoreLocation
import Foundation
import LightroomSyncCore
import Photos

enum PhotoKitImportError: Error, LocalizedError {
    case notAuthorized(PHAuthorizationStatus)
    case noPlaceholder

    var errorDescription: String? {
        switch self {
        case .notAuthorized(let status):
            return "Photos access is not allowed (status \(status.rawValue)). Enable it in System Settings › Privacy & Security › Photos."
        case .noPlaceholder:
            return "Photos did not create the asset."
        }
    }
}

/// Imports files into the system Photos library with PhotoKit, and looks up photos that are
/// already there. With iCloud Photos enabled, Photos uploads new assets to iCloud on its own.
final class PhotoKitImporter: PhotoImporting {
    private final class Box { var localIdentifier: String? }

    func importPhoto(_ request: PhotoImportRequest) async throws -> String {
        try await ensureAuthorized()
        let library = PHPhotoLibrary.shared()
        let existingAlbum = request.albumName.flatMap(Self.existingAlbum(named:))
        let box = Box()

        try await library.performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            if let name = request.originalFileName { options.originalFilename = name }
            creation.addResource(with: .photo, fileURL: request.fileURL, options: options)
            if let date = request.captureDate { creation.creationDate = date }
            // Photos reads GPS out of the file too, but only when the file has it. Setting it here
            // is what puts a photo synced from a rendition on the map along with the rest.
            if let location = request.location {
                creation.location = CLLocation(latitude: location.latitude, longitude: location.longitude)
            }
            if request.isFavorite { creation.isFavorite = true }
            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            box.localIdentifier = placeholder.localIdentifier

            if let albumName = request.albumName {
                let albumRequest: PHAssetCollectionChangeRequest?
                if let existingAlbum {
                    albumRequest = PHAssetCollectionChangeRequest(for: existingAlbum)
                } else {
                    albumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
                }
                albumRequest?.addAssets([placeholder] as NSArray)
            }
        }

        guard let identifier = box.localIdentifier else { throw PhotoKitImportError.noPlaceholder }
        return identifier
    }

    static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    private func ensureAuthorized() async throws {
        var status = Self.authorizationStatus()
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized else { throw PhotoKitImportError.notAuthorized(status) }
    }

    static func existingAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }
}

// MARK: - Finding photos that are already in the library

extension PhotoKitImporter: PhotoLibraryAccess {
    /// Finds an asset with the same original file name and roughly the same capture date.
    ///
    /// This is what keeps a second Mac from importing everything again: its local ledger is empty,
    /// but iCloud Photos has already put the assets in its Photos library.
    func findExistingAsset(matching query: PhotoMatchQuery) async throws -> String? {
        try await ensureAuthorized()
        guard let asset = Self.firstMatch(for: query) else { return nil }
        if let albumName = query.albumName {
            try? await addToAlbumIfMissing(asset, albumName: albumName)
        }
        return asset.localIdentifier
    }

    /// Narrows the library by creation date first (cheap and indexed), then compares file names,
    /// which requires reading each candidate's resources.
    private static func firstMatch(for query: PhotoMatchQuery) -> PHAsset? {
        let options = PHFetchOptions()
        let start = query.captureDate.addingTimeInterval(-query.dateTolerance) as NSDate
        let end = query.captureDate.addingTimeInterval(query.dateTolerance) as NSDate
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", start, end)
        options.includeHiddenAssets = true

        var exact: PHAsset?
        var byName: PHAsset?
        PHAsset.fetchAssets(with: .image, options: options).enumerateObjects { asset, _, stop in
            guard originalFileName(of: asset)?.caseInsensitiveCompare(query.fileName) == .orderedSame else { return }
            // Prefer a candidate whose pixel size also matches; keep the first name match otherwise,
            // since Lightroom Classic photos come back smaller than the album says.
            if let width = query.pixelWidth, let height = query.pixelHeight,
               asset.pixelWidth == width, asset.pixelHeight == height {
                exact = asset
                stop.pointee = true
            } else if byName == nil {
                byName = asset
            }
        }
        return exact ?? byName
    }

    private static func originalFileName(of asset: PHAsset) -> String? {
        let resources = PHAssetResource.assetResources(for: asset)
        let photo = resources.first { $0.type == .photo } ?? resources.first
        return photo?.originalFilename
    }

    func albumExists(named name: String) async throws -> Bool {
        try await ensureAuthorized()
        return Self.existingAlbum(named: name) != nil
    }

    /// Adds assets back into an album, recreating the album when it has been deleted. Assets that
    /// are already in it are left alone, so Photos does not end up with two references to one
    /// photo, and assets that no longer exist in the library are simply not returned.
    func addAssets(withIdentifiers identifiers: [String], toAlbumNamed name: String) async throws -> [String] {
        try await ensureAuthorized()
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        guard !assets.isEmpty else { return [] }

        let album = Self.existingAlbum(named: name)
        var alreadyInAlbum: Set<String> = []
        if let album {
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                alreadyInAlbum.insert(asset.localIdentifier)
            }
        }
        let missing = assets.filter { !alreadyInAlbum.contains($0.localIdentifier) }
        if !missing.isEmpty {
            try await PHPhotoLibrary.shared().performChanges {
                let request: PHAssetCollectionChangeRequest?
                if let album {
                    request = PHAssetCollectionChangeRequest(for: album)
                } else {
                    request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                }
                request?.addAssets(missing as NSArray)
            }
        }
        return assets.map(\.localIdentifier)
    }

    /// Keeps the configured album complete when the photo itself was already in the library.
    private func addToAlbumIfMissing(_ asset: PHAsset, albumName: String) async throws {
        var alreadyThere = false
        PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            .enumerateObjects { collection, _, stop in
                if collection.localizedTitle == albumName {
                    alreadyThere = true
                    stop.pointee = true
                }
            }
        guard !alreadyThere else { return }

        let existing = Self.existingAlbum(named: albumName)
        try await PHPhotoLibrary.shared().performChanges {
            let request: PHAssetCollectionChangeRequest?
            if let existing {
                request = PHAssetCollectionChangeRequest(for: existing)
            } else {
                request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumName)
            }
            request?.addAssets([asset] as NSArray)
        }
    }
}
#endif
