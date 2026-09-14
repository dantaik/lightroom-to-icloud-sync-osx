#if !os(macOS)
// The app itself is macOS-only. This stub keeps `swift build` working on other platforms
// so the core library and its tests can be built there.
@main
struct LightroomSyncUnsupported {
    static func main() {
        print("LightroomSync is a macOS menu bar app. Build it on macOS with scripts/build-app.sh.")
    }
}
#endif
