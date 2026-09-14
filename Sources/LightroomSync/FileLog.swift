#if os(macOS)
import Foundation

/// Appends timestamped lines to a log file. Safe to call from any thread.
final class FileLog: @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()
    private let maximumBytes: UInt64 = 2 * 1024 * 1024
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded()
        let text = "\(formatter.string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    private func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes?[.size] as? UInt64, size > maximumBytes else { return }
        let rotated = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }
}
#endif
