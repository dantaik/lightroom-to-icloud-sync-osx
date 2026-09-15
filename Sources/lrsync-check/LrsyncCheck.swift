import Foundation
import LightroomSyncCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Prints what LightroomSync sees for a shared album: its albums, the downloads setting and every
/// photo with its edit state and timestamps. With a directory argument it also downloads each
/// photo's full-size rendition there and reports the pixel size it received.
///
/// It never touches the Photos library, so it is safe to run while diagnosing a share link.
@main
struct LrsyncCheck {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let linkText = arguments.first, !linkText.hasPrefix("-") else { usage() }
        let downloadDirectory = arguments.count > 1 ? URL(fileURLWithPath: arguments[1], isDirectory: true) : nil
        exit(await run(linkText: linkText, downloadDirectory: downloadDirectory))
    }

    private static func run(linkText: String, downloadDirectory: URL?) async -> Int32 {
        var exitCode: Int32 = 0
        do {
            let client = LightroomGalleryClient(transport: URLSessionTransport())
            let link = try AlbumShareLink.parse(linkText)
            let (shareID, linkAlbumID) = try await client.resolve(link)
            let share = try await client.fetchShare(shareID: shareID)
            print("Share:            \(shareID)")
            print("Created with:     \(share.createdOnClient ?? "unknown client")")
            print("Downloads:        \(share.downloadsAllowed ? "allowed" : "DISABLED (enable “Allow downloads” in Lightroom)")")
            print("Albums:           \(share.albums.count)")
            for album in share.albums {
                print("  - \(album.name) [\(album.id)]")
            }
            guard let album = share.albums.first(where: { $0.id == linkAlbumID }) ?? share.albums.first else {
                print("No albums in this share.")
                return 1
            }

            let photos = try await client.listPhotos(shareID: shareID, albumID: album.id)
            print("\nAlbum “\(album.name)”: \(photos.count) assets")
            for photo in photos {
                let original = "\(photo.originalWidth ?? 0)×\(photo.originalHeight ?? 0)"
                let edited = "\(photo.croppedWidth ?? 0)×\(photo.croppedHeight ?? 0)"
                print("  • \(photo.fileName ?? photo.assetID) [\(photo.subtype)] original \(original), edited \(edited), edits: \(photo.hasEdits ? "yes" : "no")")
                print("      asset \(photo.assetID) captured \(format(photo.captureDate)) added \(format(photo.addedToAlbumAt)) last edit \(format(photo.lastEditedAt))")
                print("      in Photos it is looked up as \(photo.expectedPhotosFileName ?? "?")")
            }

            if let downloadDirectory {
                print("\nDownloading full-size renditions to \(downloadDirectory.path)")
                for photo in photos where photo.isImage {
                    do {
                        let file = try await client.downloadFullSize(shareID: shareID, assetID: photo.assetID, to: downloadDirectory)
                        let pixels = JPEGInfo.pixelSize(ofFileAt: file.fileURL)
                        let dimensions = pixels.map { "\($0.width)×\($0.height)" } ?? "unknown size"
                        var note = ""
                        if let pixels, let expected = photo.expectedLongEdge, pixels.longEdge + 2 < expected {
                            note = "  ⚠︎ smaller than the edited photo (\(expected) px long edge)"
                        }
                        print("  ✓ \(file.fileName ?? photo.assetID): \(dimensions), \(file.byteCount) bytes\(note)")
                    } catch {
                        print("  ✗ \(photo.fileName ?? photo.assetID): \(error.localizedDescription)")
                        exitCode = 1
                    }
                }
            }
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
        return exitCode
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "-" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func usage() -> Never {
        let text = """
        usage: lrsync-check <share link> [download directory]

          share link          https://adobe.ly/… or https://lightroom.adobe.com/shares/…
          download directory  optional; downloads every photo's full-size rendition there
        """
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
    }
}
