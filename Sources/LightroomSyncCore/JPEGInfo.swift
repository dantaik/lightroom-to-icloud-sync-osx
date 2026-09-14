import Foundation

/// Reads pixel dimensions from a JPEG's Start-Of-Frame marker without decoding the image.
public enum JPEGInfo {
    public struct PixelSize: Equatable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public var longEdge: Int { max(width, height) }
    }

    private static let startOfFrameMarkers: Set<UInt8> = [
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    ]

    public static func pixelSize(of data: Data) -> PixelSize? {
        data.withUnsafeBytes { raw -> PixelSize? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
            var index = 2
            while index + 3 < count {
                guard bytes[index] == 0xFF else { index += 1; continue }
                let marker = bytes[index + 1]
                if marker == 0xFF { index += 1; continue }                       // fill byte
                if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { // standalone markers
                    index += 2
                    continue
                }
                if marker == 0xD9 || marker == 0xDA { return nil }                // EOI / SOS before any SOF
                let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
                if startOfFrameMarkers.contains(marker) {
                    guard index + 8 < count else { return nil }
                    let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                    let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                    return PixelSize(width: width, height: height)
                }
                guard length >= 2 else { return nil }
                index += 2 + length
            }
            return nil
        }
    }

    public static func pixelSize(ofFileAt url: URL) -> PixelSize? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return pixelSize(of: data)
    }
}
