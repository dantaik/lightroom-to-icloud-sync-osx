import Foundation

/// How large a photo is when it lands in Photos.
///
/// Lightroom renders at whatever size the camera shot, which is far more than any screen can show
/// and the slowest part of a sync: a 60 MP render is a 25 MB JPEG to download from Adobe, then to
/// upload to iCloud, then to keep on every device. Each size here caps the long edge instead, and
/// the default still fills Apple's largest display pixel for pixel.
public enum PhotoSize: String, Codable, CaseIterable, Equatable, Identifiable {
    /// 6016 px: the width of a Pro Display XDR, so a landscape photo is a background for it with
    /// nothing scaled. Every smaller Apple display is covered by the same file.
    case large
    /// 3840 px: 4K. Native on every display other than the XDR, at a quarter of the pixels.
    case medium
    /// 2048 px: the size Lightroom already holds a rendition of, so it needs no full-size render.
    case small
    /// Whatever Lightroom renders, uncapped. What the app did before sizes existed.
    case original

    /// Pro Display XDR: 6016 × 3384 at 218 ppi.
    public static let proDisplayXDRWidth = 6016

    public static let `default` = PhotoSize.large

    public var id: String { rawValue }

    /// The longest edge a synced photo may have, or nil to keep Lightroom's full-size render.
    public var maxLongEdge: Int? {
        switch self {
        case .large: return Self.proDisplayXDRWidth
        case .medium: return 3840
        case .small: return 2048
        case .original: return nil
        }
    }

    /// The rendition Lightroom already holds at this size, if there is one. Fetching that instead
    /// skips the full-size render altogether, which is most of what a sync spends its time on.
    /// Only 2048 px and smaller are offered as renditions; anything larger comes from the
    /// download host and is shrunk here.
    public var renditionType: String? {
        self == .small ? "2048" : nil
    }

    public var title: String {
        switch self {
        case .large: return "Large"
        case .medium: return "Medium"
        case .small: return "Small"
        case .original: return "Original"
        }
    }

    /// "Large — 6016 px", which is what the picker shows.
    public var menuLabel: String {
        guard let maxLongEdge else { return "\(title) — full size" }
        return "\(title) — \(maxLongEdge) px"
    }

    /// "6016 px" or "full size", for the log and the saved-settings line.
    public var shortDescription: String {
        guard let maxLongEdge else { return "full size" }
        return "\(maxLongEdge) px"
    }

    /// What choosing this size means, for the line under the picker.
    public var summary: String {
        switch self {
        case .large:
            return "6016 px on the long edge: a background for a Pro Display XDR pixel for pixel, and more than native on any smaller screen."
        case .medium:
            return "3840 px on the long edge, which is 4K. Native on every display but the XDR, at a quarter of the pixels of Large."
        case .small:
            return "2048 px on the long edge. By far the fastest: Lightroom already holds this rendition, so nothing full-size is downloaded."
        case .original:
            return "Every pixel Lightroom renders. Slow to download and slow for iCloud to carry, and more than any screen can show."
        }
    }

    /// How big the photo should end up: its own edited size, capped by this one. Nil when
    /// Lightroom does not say how big the edited photo is, and nothing can be expected.
    ///
    /// This is what a served photo is measured against, so that a deliberately small size is not
    /// reported as Lightroom having served less than it should.
    public func intendedLongEdge(editedLongEdge: Int?) -> Int? {
        guard let editedLongEdge else { return nil }
        guard let maxLongEdge else { return editedLongEdge }
        return min(editedLongEdge, maxLongEdge)
    }
}
