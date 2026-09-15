import Foundation

/// Lightroom's own library on this Mac: where it is, and what it actually holds.
///
/// The app reads a *shared album* over the network, which needs nothing installed locally. But on
/// the Mac the photographer edits on, Lightroom has already rendered much of what the app would
/// otherwise download, and a file already on disk beats one Adobe has to build on demand.
///
/// What is worth taking from it is narrower than it first looks, so ``survey(_:)`` reports what is
/// there rather than assuming:
///
/// - `originals/` holds the files as they came off the camera, and only when *Store a copy of all
///   originals locally* is turned on in Lightroom's Local Storage preferences. The edits are not
///   in these files — they are Camera Raw develop settings — so they cannot stand in for an
///   edited render. See ``LocalPhotoSource``.
/// - `previews.noindex/` holds renders with the edits applied, which is the right kind of file.
///   The question is only ever how large they are, and that is what the survey measures: a
///   preview can stand in for a synced photo only up to the size it covers.
public enum LightroomLibrary {
    /// Where Lightroom (the cloud-based one, not Classic) puts its library by default.
    public static let defaultRelativePath = "Pictures/Lightroom Library.lrlibrary"

    /// The directories inside the package worth reporting on, and what each one is.
    public static let knownFolders: [(path: String, meaning: String)] = [
        ("originals", "original files, present only with “Store a copy of all originals locally” on"),
        ("previews.noindex", "renders with the edits applied — the only kind that can replace a download"),
        ("managedCatalog.noindex", "the catalogue itself"),
        ("helper.noindex", "Lightroom's own scratch space"),
    ]

    /// The library in a home directory, if there is one.
    public static func locate(inHome home: URL) -> URL? {
        let candidate = home.appendingPathComponent(defaultRelativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return candidate
    }

    /// What one directory inside the library holds.
    public struct Folder: Equatable {
        /// Path relative to the library package.
        public let path: String
        public let fileCount: Int
        public let byteCount: Int
        /// How many files carry each extension, lowercased.
        public let extensions: [String: Int]
        /// Long edges of the JPEGs that could be measured, sorted ascending. Empty when the
        /// folder holds nothing readable as a JPEG — which is the normal answer for `originals`,
        /// where the files are raw.
        public let sampledLongEdges: [Int]
        /// A few file paths relative to the library, as they are actually named on disk.
        ///
        /// This is what says how a photo could be looked up: whether a file is named for the
        /// asset ID the shared album reports, for a hash, or for something the catalogue alone
        /// can resolve. Nothing can be matched to a photo until that is known.
        public let samplePaths: [String]

        public init(path: String, fileCount: Int, byteCount: Int, extensions: [String: Int],
                    sampledLongEdges: [Int], samplePaths: [String] = []) {
            self.path = path
            self.fileCount = fileCount
            self.byteCount = byteCount
            self.extensions = extensions
            self.sampledLongEdges = sampledLongEdges
            self.samplePaths = samplePaths
        }
    }

    public struct Report: Equatable {
        public let libraryURL: URL
        public let folders: [Folder]

        public init(libraryURL: URL, folders: [Folder]) {
            self.libraryURL = libraryURL
            self.folders = folders
        }

        public func folder(_ path: String) -> Folder? { folders.first { $0.path == path } }

        public var totalBytes: Int { folders.reduce(0) { $0 + $1.byteCount } }

        /// The largest render found anywhere under `previews.noindex`. This is the number that
        /// decides whether the local library can serve a given photo size at all.
        public var largestPreviewLongEdge: Int? {
            folder("previews.noindex")?.sampledLongEdges.last
        }

        /// Which of the app's photo sizes this library could serve without downloading, judged on
        /// the largest preview found. "Original" is never among them: it means every pixel
        /// Lightroom renders, which no cached file can promise to be.
        public var servablePhotoSizes: [PhotoSize] {
            guard let largest = largestPreviewLongEdge else { return [] }
            return PhotoSize.allCases.filter { size in
                guard let maxLongEdge = size.maxLongEdge else { return false }
                return largest >= maxLongEdge
            }
        }
    }

    /// Walks a library and reports what each of its directories holds.
    ///
    /// - Parameter sampleLimit: how many files per directory to open and measure. Measuring means
    ///   reading a JPEG header, so a library of tens of thousands of previews is sampled rather
    ///   than read through.
    public static func survey(_ libraryURL: URL, sampleLimit: Int = 400) throws -> Report {
        var folders: [Folder] = []
        for known in knownFolders {
            let folderURL = libraryURL.appendingPathComponent(known.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            folders.append(try measure(folderURL, path: known.path, sampleLimit: sampleLimit))
        }
        return Report(libraryURL: libraryURL, folders: folders)
    }

    /// How many file names per directory to show. Enough to see the shape of the naming; few
    /// enough that the output can be pasted into an issue.
    static let namesToSample = 5

    private static func measure(_ folderURL: URL, path: String, sampleLimit: Int) throws -> Folder {
        var fileCount = 0
        var byteCount = 0
        var extensions: [String: Int] = [:]
        var longEdges: [Int] = []
        var samplePaths: [String] = []
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: folderURL,
                                              includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                              options: [.skipsHiddenFiles]) else {
            return Folder(path: path, fileCount: 0, byteCount: 0, extensions: [:], sampledLongEdges: [])
        }
        for case let fileURL as URL in walker {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            fileCount += 1
            byteCount += values?.fileSize ?? 0
            let ext = fileURL.pathExtension.lowercased()
            extensions[ext.isEmpty ? "(none)" : ext, default: 0] += 1
            // Measuring costs a file open, so only the first so many per directory are measured;
            // previews come in a handful of sizes, and a sample finds all of them.
            if longEdges.count < sampleLimit, let size = JPEGInfo.pixelSize(ofFileAt: fileURL) {
                longEdges.append(size.longEdge)
            }
            if samplePaths.count < Self.namesToSample {
                samplePaths.append(String(fileURL.path.dropFirst(folderURL.path.count + 1)))
            }
        }
        return Folder(path: path, fileCount: fileCount, byteCount: byteCount,
                      extensions: extensions, sampledLongEdges: longEdges.sorted(),
                      samplePaths: samplePaths)
    }
}
