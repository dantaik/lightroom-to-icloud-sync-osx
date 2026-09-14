#if os(macOS)
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

/// Imports files into the system Photos library with PhotoKit. With iCloud Photos enabled,
/// Photos uploads the new asset to iCloud on its own.
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

    private static func existingAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }
}
#endif
