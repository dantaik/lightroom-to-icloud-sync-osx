import Foundation
import LightroomSyncCore

/// Reports what Lightroom's library on this Mac holds, and which of the app's photo sizes it
/// could serve without downloading anything.
///
/// The app syncs from a *shared album* over the network, which needs nothing installed locally.
/// On the Mac Lightroom actually runs on, though, some of what would be downloaded has already
/// been rendered and is sitting on disk. Whether that is worth using comes down to one number —
/// how large Lightroom's renders are — and this prints it.
///
/// It only reads, and it never touches the Photos library or the network.
@main
struct LrsyncLocal {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("-h") || arguments.contains("--help") { usage() }

        let libraryURL: URL?
        if let explicit = arguments.first {
            libraryURL = URL(fileURLWithPath: explicit, isDirectory: true)
        } else {
            libraryURL = LightroomLibrary.locate(inHome: FileManager.default.homeDirectoryForCurrentUser)
        }

        guard let libraryURL else {
            print("No Lightroom library found at ~/\(LightroomLibrary.defaultRelativePath).")
            print("""

                That means one of:
                  - Lightroom (the cloud-based one) is not installed on this Mac, or
                  - its library lives somewhere else — pass the path as an argument, or
                  - you use Lightroom Classic, whose catalogue is a .lrcat and is not this.

                Nothing is wrong either way: the app syncs over the network and does not need a
                local library. This only reports whether one could save it some downloading.
                """)
            exit(1)
        }

        do {
            let report = try LightroomLibrary.survey(libraryURL)
            print(describe(report))
            exit(0)
        } catch {
            print("Could not read \(libraryURL.path): \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func describe(_ report: LightroomLibrary.Report) -> String {
        var lines: [String] = []
        lines.append("Library:  \(report.libraryURL.path)")
        lines.append("On disk:  \(bytes(report.totalBytes))")
        lines.append("")

        if report.folders.isEmpty {
            lines.append("None of the directories this tool knows about are present.")
            lines.append("The library may be a newer layout than the app expects; the paths it looked for are:")
            for known in LightroomLibrary.knownFolders { lines.append("  \(known.path)") }
            return lines.joined(separator: "\n")
        }

        for folder in report.folders {
            let meaning = LightroomLibrary.knownFolders.first { $0.path == folder.path }?.meaning ?? ""
            lines.append("\(folder.path)")
            if !meaning.isEmpty { lines.append("  \(meaning)") }
            lines.append("  files: \(folder.fileCount), \(bytes(folder.byteCount))")
            if !folder.extensions.isEmpty {
                let listed = folder.extensions.sorted { $0.value > $1.value }.prefix(6)
                    .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
                lines.append("  kinds: \(listed)")
            }
            if let smallest = folder.sampledLongEdges.first, let largest = folder.sampledLongEdges.last {
                let distinct = Set(folder.sampledLongEdges).sorted()
                lines.append("  long edges measured (\(folder.sampledLongEdges.count) sampled): \(smallest)–\(largest) px")
                if distinct.count <= 8 {
                    lines.append("  sizes present: \(distinct.map(String.init).joined(separator: ", ")) px")
                }
            } else if folder.fileCount > 0 {
                lines.append("  long edges: nothing here is a render this tool can measure")
            }
            for path in folder.samplePaths { lines.append("    \(path)") }
            lines.append("")
        }

        lines.append("What this means for syncing")
        lines.append("")
        guard let largest = report.largestPreviewLongEdge else {
            lines.append("  No measurable renders were found, so every photo still has to be downloaded.")
            return lines.joined(separator: "\n")
        }
        lines.append("  Largest render Lightroom has already made: \(largest) px on the long edge.")
        let servable = report.servablePhotoSizes
        if servable.isEmpty {
            lines.append("  That covers none of the sizes the app offers, so every photo is still downloaded.")
        } else {
            lines.append("  Sizes that could be served from disk instead of downloaded:")
            for size in servable { lines.append("    \(size.menuLabel)") }
        }
        let unservable = PhotoSize.allCases.filter { !servable.contains($0) }
        if !unservable.isEmpty {
            lines.append("  Still downloaded, because no render on disk is large enough:")
            for size in unservable { lines.append("    \(size.menuLabel)") }
        }
        lines.append("")
        lines.append("  Originals are never substituted, however many are stored locally: Lightroom's")
        lines.append("  edits are develop settings rather than pixels, and applying them needs Adobe's")
        lines.append("  rendering engine. An original would land in Photos looking nothing like the")
        lines.append("  photo in Lightroom.")
        return lines.joined(separator: "\n")
    }

    private static func bytes(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(count) B" : String(format: "%.1f %@", value, units[unit])
    }

    private static func usage() -> Never {
        print("""
            usage: lrsync-local [path/to/Lightroom Library.lrlibrary]

            Reports what Lightroom's library on this Mac holds and which photo sizes it could
            serve without downloading. Defaults to ~/\(LightroomLibrary.defaultRelativePath).

            Reads only. Never touches the Photos library or the network.
            """)
        exit(2)
    }
}
