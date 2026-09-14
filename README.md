# Lightroom Sync — shared Lightroom album → iCloud Photos (macOS menu bar app)

Lightroom Sync watches one album in **Lightroom** (the cloud-based Lightroom, not Lightroom Classic) and adds every photo in it, as a **full-resolution JPEG with your edits applied**, to the Photos library on your Mac. With iCloud Photos enabled, Photos then uploads it to iCloud like any other picture.

It runs as a small menu bar app, checks the album on an interval you choose, and never touches a photo twice: once a photo has been synced, later edits in Lightroom do not re-sync it.

No Adobe developer account, no Lightroom Classic, no Adobe API key. It uses the same public endpoints that Lightroom's own web gallery uses for a shared album (see [How it works](#how-it-works)).

## Requirements

- macOS 13 Ventura or later, Xcode 15+ command line tools (`xcode-select --install`) to build.
- Photos with **iCloud Photos** turned on for the System Photo Library (Photos › Settings › iCloud).
- A Lightroom album shared by link with **Allow downloads** enabled.

## Setup

1. **Share the album from Lightroom.** In Lightroom (desktop, web or mobile) open the album, choose *Share & Invite*, set *Link access* to **Anyone can view**, and under *Link settings* turn on **Allow downloads**. Copy the link (it looks like `https://adobe.ly/…` or `https://lightroom.adobe.com/shares/…`).
2. **Build and install the app** (see below), then open it. It appears as a photo icon in the menu bar.
3. Click the icon and paste the link into *Lightroom album share link*. The panel confirms the album name and that downloads are allowed.
4. Optionally type a **Photos album** name. The app creates it if needed and adds every synced photo to it. Leave it empty to add photos to the library only.
5. Set **Check every N min** and, if you like, **Start at login**.

That's it. The app checks the album on that interval and on every launch.

### Sync rules

- A photo becomes eligible once it has been in the shared album for at least the check interval. That gives you the interval to finish your first edits before the version is captured.
- A photo edited within the last two minutes waits for the next check, so an edit in progress is not captured half done.
- Once synced, a photo is recorded in a local ledger and is **never synced again**, however often it is edited later. Removing it from the Lightroom album or from Photos does not resync it either.
- If the same original (same file hash) appears twice in the album, it is imported once.
- **Sync now** in the panel checks immediately and ignores both delays.
- Videos are listed but skipped. Only photos are synced.

### Build

```sh
git clone https://github.com/dantaik/lightroom-to-icloud-sync-osx.git
cd lightroom-to-icloud-sync-osx
make app        # builds dist/LightroomSync.app (release, ad-hoc signed)
make install    # copies it to /Applications
open /Applications/LightroomSync.app
```

The first time a photo is imported macOS asks for permission to access Photos. If you dismissed it, grant it under *System Settings › Privacy & Security › Photos*.

The build is signed ad hoc, which is fine for an app you built yourself. Rebuilding changes the signature, so macOS may ask for Photos permission again after a rebuild. To avoid that, sign with your own certificate: `CODESIGN_IDENTITY="Apple Development: …" make app`.

`make test` runs the unit tests of the core library. They also run on Linux, which is how the sync logic was developed and verified.

### Diagnostics

`lrsync-check` prints what the app sees for a share link and can download the photos to a folder, without touching Photos:

```sh
swift run lrsync-check "https://adobe.ly/xxxxxxx"
swift run lrsync-check "https://adobe.ly/xxxxxxx" ~/Desktop/lightroom-test
```

The app also writes a log to `~/Library/Logs/LightroomSync/sync.log` (*Open log* in the panel). The ledger of synced photos lives in `~/Library/Application Support/LightroomSync/ledger.json`; delete it to make the app treat every photo as new.

## How it works

Adobe's official Lightroom API is not usable for this: the Firefly Services "Lightroom API" reached end of life on July 31, 2026, and the older partner catalog API is invitation-only with full-size renditions gated behind a scope Adobe grants by hand. Lightroom desktop has no plugin, AppleScript or Shortcuts support either. See [docs/research.md](docs/research.md) for the details and sources.

What does work, and what this app uses, is the web gallery of a shared album. Its page talks to three unauthenticated endpoints:

```
GET https://lightroom.adobe.com/v2c/spaces/{shareID}                       share settings (downloads on/off)
GET https://lightroom.adobe.com/v2c/spaces/{shareID}/resources             the albums in the share
GET https://lightroom.adobe.com/v2c/spaces/{shareID}/albums/{albumID}/assets?embed=asset
                                                                           photos with timestamps, edit state, file names
GET https://dl.lightroom.adobe.com/spaces/{shareID}/assets/{assetID}       full-size edited JPEG (403 when downloads are off)
```

The last call is exactly what the gallery's *Download* button does. For photos whose originals live in Lightroom's cloud it returns a JPEG at the edited photo's full pixel size, with EXIF, XMP and the ICC profile embedded. Photos that only reached the cloud as smart previews (synced from Lightroom Classic) come back at 2048 px; the app imports them anyway and logs a warning.

On the Mac side the app imports each file with PhotoKit (`PHAssetCreationRequest`), sets the capture date, adds it to the chosen album, and records the Photos identifier in the ledger.

## Caveats

- **These endpoints are not documented by Adobe** and could change. The app fails loudly (menu bar icon and log) rather than doing something odd if the responses stop making sense.
- **Sharing by link means anyone with the link can view and download the album.** The link is unguessable, but treat it as such. Invite-only shares cannot be read without an Adobe login.
- The app polls with one small JSON request per interval and only contacts the download host for new photos. Keep the interval reasonable; the default is 15 minutes.
- Live Photos, RAW originals and videos are not transferred as such. You get a rendered JPEG of each photo, which is the point of the tool.
- Not affiliated with Adobe or Apple.

## Project layout

```
Sources/LightroomSyncCore   platform-independent logic: share-link parsing, gallery client, sync policy, ledger, engine
Sources/LightroomSync       the macOS menu bar app (SwiftUI MenuBarExtra + PhotoKit importer)
Sources/lrsync-check        command-line diagnostics
Tests/LightroomSyncCoreTests unit tests with captured (anonymized) gallery responses as fixtures
scripts/                    Info.plist and the .app bundling script
docs/research.md            why this approach, with sources
```
