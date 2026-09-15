#if os(macOS)
import AppKit

/// The images behind the menu bar item.
///
/// The spinner is a set of pre-rotated copies of one symbol rather than a rotation effect on a
/// SwiftUI view: a `MenuBarExtra` label is rendered into the status item, where an animating
/// modifier is not reliably honoured, but a plain image always is. Showing one frame after another
/// is therefore what actually turns.
@MainActor
enum MenuBarIcon {
    /// 12 frames of 30° each, which reads as smooth at the size of a menu bar item.
    static let spinnerFrameCount = 12

    static let idleSymbol = "photo.on.rectangle.angled"
    static let syncingSymbol = "arrow.triangle.2.circlepath"
    static let failedSymbol = "exclamationmark.triangle"

    private static var symbols: [String: NSImage] = [:]
    private static var spinnerFrames: [NSImage] = []

    /// A template image for an SF Symbol, sized for the menu bar.
    static func symbol(_ name: String) -> NSImage {
        if let cached = symbols[name] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular, scale: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        symbols[name] = image
        return image
    }

    /// One frame of the turning sync symbol. Frames are built once and kept.
    static func spinner(frame: Int) -> NSImage {
        if spinnerFrames.isEmpty {
            let base = symbol(syncingSymbol)
            spinnerFrames = (0..<spinnerFrameCount).map { index in
                // Negative degrees so it turns clockwise: AppKit's default coordinates are y-up,
                // where a positive angle goes the other way.
                rotated(base, degrees: -360.0 * Double(index) / Double(spinnerFrameCount))
            }
        }
        let index = ((frame % spinnerFrameCount) + spinnerFrameCount) % spinnerFrameCount
        return spinnerFrames[index]
    }

    private static func rotated(_ image: NSImage, degrees: Double) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let result = NSImage(size: size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: CGFloat(degrees))
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        result.isTemplate = true
        return result
    }
}
#endif
