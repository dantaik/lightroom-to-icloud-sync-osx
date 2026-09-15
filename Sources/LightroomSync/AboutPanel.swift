#if os(macOS)
import AppKit
import SwiftUI

/// What the app does and what it cannot do, in a window of its own.
///
/// Worth stating in the app rather than only in the README: this syncs through a public share
/// link, it uses endpoints Adobe does not document, and it deliberately never syncs a photo twice.
/// Someone who does not know that will read the behaviour as a bug.
struct AboutView: View {
    static let repositoryURL = URL(string: "https://github.com/dantaik/lightroom-to-icloud-sync-osx")

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return "Version \(short)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                section("How it works", items: behaviour)
                Divider()
                section("What it cannot do", items: limits, symbolColor: .orange)
                Divider()
                footer
            }
            .padding(22)
            .frame(width: 460, alignment: .leading)
        }
        .frame(width: 460, height: 620)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Lightroom Sync")
                    .font(.title2.weight(.semibold))
                Text(version)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                Text("Copies photos from one shared Lightroom album into Photos, so iCloud Photos carries them to your devices.")
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private let behaviour = [
        "Every photo arrives as a JPEG with your Lightroom edits already applied, then goes into your Photos library. With iCloud Photos on, Photos uploads it like any other picture.",
        "Photo size decides how long that takes. Large, the default, is 6016 px on the long edge, which fills a Pro Display XDR pixel for pixel; Small is fetched straight from Lightroom's own 2048 px rendition and is by far the quickest; Original keeps every pixel Lightroom renders.",
        "A photo syncs once it has been in the album for at least the check interval, which leaves you that long to make your first edits.",
        "A photo is synced once and then never again, however often you edit it afterwards. The record lives in a ledger file on this Mac.",
        "Photos your library already holds are recognised and skipped, so a second Mac does not import the album a second time.",
        "The Photos album you name is kept filled: it is recreated if you delete it, and renaming it here moves the synced photos across.",
        "Nothing runs until you press Save, and checks always use the saved settings, never what you are still typing.",
    ]

    private let limits = [
        "The Lightroom album has to be shared by link with “Allow downloads” turned on. Anyone holding that link can view and download the album.",
        "It reads the endpoints behind Lightroom's own web gallery, which Adobe does not document and could change without warning. There is no supported Adobe API for this.",
        "Photos that reached Adobe's cloud from Lightroom Classic exist there only as smart previews, so they arrive at 2048 pixels on the long edge. The log says when that happens.",
        "You get a rendered JPEG, not the RAW original. Videos and Live Photos are skipped.",
        "Edits you make after a photo has synced are not sent again, by design. Deleting the photo from Photos does not bring it back either.",
        "Use one Mac at a time, and let Photos finish syncing from iCloud before starting the app on a second one.",
        "Not affiliated with, or endorsed by, Adobe or Apple.",
    ]

    private func section(_ title: String, items: [String], symbolColor: Color = .accentColor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(symbolColor)
                        .padding(.top, 6)
                    Text(item)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url = Self.repositoryURL {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(Color.secondary)
                    Link("Source code on GitHub", destination: url)
                }
                .font(.callout)
            }
            Text("Open source under the MIT licence. Issues and pull requests are welcome.")
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Owns the About window. A menu bar app has no windows of its own, so this makes one and keeps
/// it alive; showing it again brings the same window forward rather than opening a second.
@MainActor
final class AboutWindow {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: controller)
        window.title = "About Lightroom Sync"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
