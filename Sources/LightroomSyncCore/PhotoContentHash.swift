import Crypto
import Foundation

/// Identifies a JPEG by its picture alone: a SHA-256 taken over everything the file says about
/// how the image is coded and what its pixels are, and nothing it says *about* the photo.
///
/// Lightroom's own `sha256` is the hash of the original as it was imported, which the album
/// listing carries — so it settles a duplicate before anything is downloaded, and this cannot
/// replace it. This answers the case that one leaves open: two assets that are plainly the same
/// photograph but hash differently there, because Lightroom reports no hash for one of them, or a
/// different one for each copy. Two such copies are served as the same pixels, so they land here
/// as the same digest whatever their file names or EXIF say.
///
/// Every metadata segment is left out — `APP0`–`APP15`, which carry JFIF, EXIF, XMP and the ICC
/// profile, and `COM` comments — so a copy that was described differently, or not at all, still
/// matches. What is hashed is the frame, quantization and Huffman tables, the scan header, and
/// the entropy-coded picture that follows it.
///
/// Anything that does not parse cleanly returns nil rather than a doubtful digest: a photo with
/// no content hash simply falls back on the identities that do not need one.
public enum PhotoContentHash {
    /// Segments holding what is said *about* the photo rather than the photo.
    private static let applicationMarkers: ClosedRange<UInt8> = 0xE0...0xEF
    private static let comment: UInt8 = 0xFE
    /// Markers that stand alone, carrying no length and no payload.
    private static let restarts: ClosedRange<UInt8> = 0xD0...0xD7
    private static let startOfImage: UInt8 = 0xD8
    private static let endOfImage: UInt8 = 0xD9
    private static let startOfScan: UInt8 = 0xDA
    private static let temporary: UInt8 = 0x01

    public static func sha256(ofFileAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256(of: data)
    }

    public static func sha256(of data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
            var hasher = Crypto.SHA256()
            var index = 2

            /// Adds a stretch of the file to the digest exactly as it stands.
            func hash(_ range: Range<Int>) {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[range]))
            }

            while index + 1 < count {
                guard bytes[index] == 0xFF else { return nil }
                // Any number of 0xFF bytes may pad the run-up to a marker code.
                var markerIndex = index + 1
                while markerIndex < count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
                guard markerIndex < count else { return nil }
                let marker = bytes[markerIndex]

                if marker == endOfImage { break }
                if marker == startOfImage || marker == temporary || restarts.contains(marker) {
                    index = markerIndex + 1
                    continue
                }

                guard markerIndex + 2 < count else { return nil }
                let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
                guard length >= 2, markerIndex + 1 + length <= count else { return nil }
                let segmentEnd = markerIndex + 1 + length

                if marker == startOfScan {
                    // The scan header, and then the picture itself: entropy-coded bytes running
                    // to the end of the file, restart markers and all.
                    hash(index..<count)
                    return hexadecimal(hasher.finalize())
                }
                if !applicationMarkers.contains(marker), marker != comment {
                    hash(index..<segmentEnd)
                }
                index = segmentEnd
            }
            // No scan: there is no picture here to identify.
            return nil
        }
    }

    private static func hexadecimal(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
