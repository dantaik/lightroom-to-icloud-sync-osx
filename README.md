<img src="docs/app-icon.png" alt="" width="104" align="left">

# Lightroom Sync

**A macOS menu bar app that copies a shared Lightroom album into iCloud Photos.**
Full-resolution JPEGs with your edits applied, each photo synced once and never again.

<br clear="left">

Lightroom Sync watches one album in **Lightroom** (the cloud-based Lightroom, not Lightroom Classic) and adds every photo in it to the Photos library on your Mac, as a full-resolution JPEG with your edits already applied. With iCloud Photos enabled, Photos uploads it like any other picture, so the album reaches your iPhone and iPad.

It needs no Adobe developer account, no API key and no Lightroom Classic. It reads the same endpoints Lightroom's own web gallery uses for a shared album; see [How it works](#how-it-works).

---

## Requirements

| | |
|---|---|
| **macOS** | 13 Ventura or later |
| **To build** | Xcode Command Line Tools: `xcode-select --install` |
| **To run the tests** | Full Xcode, because XCTest ships only there (optional) |
| **Photos** | iCloud Photos turned on for the System Photo Library (Photos › Settings › iCloud) |
| **Lightroom** | An album shared by link with **Allow downloads** turned on |

## Build and install

Four commands, from a clean machine to a running app:

```sh
git clone https://github.com/dantaik/lightroom-to-icloud-sync-osx.git
cd lightroom-to-icloud-sync-osx
make app                              # builds dist/LightroomSync.app
make install                          # copies it to /Applications
open /Applications/LightroomSync.app  # the icon appears in the menu bar
```

`make app` compiles a release build, assembles the `.app` bundle with its icon and `Info.plist`, and signs it ad hoc. There is nothing to configure and no dependencies to fetch: the package has none.

A few things worth knowing:

- **The menu bar is the whole app.** There is no Dock icon and no main window, by design.
- **Photos will ask for permission** the first time a photo is imported. If you dismiss it, grant access under *System Settings › Privacy & Security › Photos*.
- **Ad-hoc signing is fine for an app you built yourself**, and Gatekeeper does not object to a locally built binary. Each rebuild produces a new signature, though, which can make macOS ask for Photos permission again. To keep one identity across rebuilds, sign with your own certificate:
  ```sh
  CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" make app
  ```
- **To update**, pull and rebuild. Your settings and the record of synced photos live outside the app bundle and survive:
  ```sh
  git pull && make install
  ```
- **To uninstall**, quit the app, delete `/Applications/LightroomSync.app`, and remove
  `~/Library/Application Support/LightroomSync` and `~/Library/Logs/LightroomSync`.

### Other make targets

| Command | What it does |
|---|---|
| `make app` | Builds `dist/LightroomSync.app` |
| `make install` | Builds, then copies the app to `/Applications` |
| `make run` | Builds and launches it |
| `make test` | Runs the core library's unit tests (needs full Xcode on macOS) |
| `make clean` | Removes `.build` and `dist` |

If `make test` reports `no such module 'XCTest'`, the toolchain is pointed at the Command Line Tools rather than Xcode. Fix it once with:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The same tests also run on Linux, which is where the sync logic was developed and verified. Building the app itself never needs full Xcode.

### Regenerating the icon

The icon is committed as `Resources/AppIcon.icns`, so building does not need Python. If you change the artwork in `scripts/make-icon.py`, regenerate it with:

```sh
python3 -m pip install Pillow
python3 scripts/make-icon.py
```

## Setting it up

1. **Share the album from Lightroom.** Open the album in Lightroom (desktop, web or mobile), choose *Share & Invite*, set *Link access* to **Anyone can view**, and under *Link settings* turn on **Allow downloads**. Copy the link; it looks like `https://adobe.ly/…` or `https://lightroom.adobe.com/shares/…`.
2. Click the menu bar icon and paste the link into *Lightroom album share link*.
3. Optionally name a **Photos album**. The app creates it if it does not exist. Leave it empty to add photos to the library only.
4. Set **Check every** to a number and a unit: minutes, hours or days. Turn on **Start at login** if you want it running all the time.
5. Press **Save**. The app then reads the album and confirms its name and that downloads are allowed.

The ⓘ button in the panel's top right corner summarises the same behaviour and limits described below, and links to this repository.

### Saved settings are the only settings

Nothing happens until you press Save, and nothing ever runs against what you are still typing:

- The panel edits a draft. Scheduled checks, **Sync now**, and the reading of the share link all use the **saved** settings, never the draft.
- While there are unsaved edits the panel says so, **Sync now** is disabled, and scheduled checks do not start. Press **Save** to apply them, or **Revert** to go back to what is saved.
- Saving also schedules the next check right away, rather than waiting out the old interval.
- Clearing the share link and saving stops the checks altogether.
- **Start at login** is a system setting and takes effect when you click it, not on Save.

Before the first Save the app does nothing at all: no checks, and no requests to Adobe.

## How syncing behaves

- A photo becomes eligible once it has been in the shared album for at least the check interval. That gives you the interval to finish your first edits before the version is captured, so a longer interval is also a longer grace period.
- A photo edited within the last two minutes waits for the next check, so an edit in progress is not captured half done.
- Once synced, a photo is recorded in a local ledger and is **never synced again**, however often it is edited later. Removing it from the Lightroom album or from Photos does not resync it.
- If the same original (same file hash) appears twice in the album, it is imported once.
- Before downloading anything, the app asks Photos whether the photo is already there. See [Using two Macs](#using-two-macs).
- The configured Photos album is repaired, not just filled. See [The Photos album](#the-photos-album).
- **Sync now** checks immediately and ignores both delays.
- Videos are listed but skipped. Only photos are synced.

### The Photos album

Deleting an album in Photos does not delete the photos in it, and a photo the app has already synced is never synced again. Left alone, that combination would mean a deleted album stays empty forever and a check reports that there is nothing to do.

So every check also makes sure the configured album holds the photos that have been synced from the Lightroom album. It puts them back when the album is missing, which is what happens if you delete it, and when you change the album name in the settings, which moves the synced photos into the new album. Correcting a name is therefore enough to repair a wrong one; the empty album with the old name stays behind for you to delete.

A photo you took out of an album that still exists is left out: that is a deliberate act, not a missing album. A photo deleted from the Photos library altogether is not re-imported either, since the ledger still records it as synced; the log says how many are in that state.

### Using two Macs

The ledger of synced photos is a local file, so a second Mac starts out knowing nothing. To keep it from importing the whole album again, the app checks the Photos library itself before downloading anything: iCloud Photos has already put the assets on both machines, so a photo that is present there has been synced before, whichever Mac did it.

A photo counts as already present when an asset in the library has the **same original file name** and a **creation date within a day** of Lightroom's capture date. Lightroom always serves a JPEG named after the original, so `L1009709.DNG` is looked up as `L1009709.jpg`. Both must match, which makes a false match implausible: the same camera file name within a day of the same capture time is the same photograph. The day of slack absorbs the two Macs reading Lightroom's zone-less capture time in different time zones. When several assets match by name, the one whose pixel size also matches wins. If you configured a Photos album and the matched photo is not in it, it is added.

Two things this does not cover:

- Let Photos finish syncing from iCloud on the second Mac before starting the app. Photos it has not received yet cannot be found, and would be imported again.
- Run the app on one Mac at a time. Two Macs checking the same album within the same minute can both import the same photo before either one appears in the other's library.

A photo without a capture date is not looked up at all, since the search would have to scan the whole library; it is simply downloaded. If the Photos check fails (no permission, for example), the app logs a warning and syncs the photo: a duplicate is better than a photo that never arrives.

## Where things are kept

| Path | What |
|---|---|
| `~/Library/Application Support/LightroomSync/ledger.json` | The record of synced photos. Delete it to make the app treat every photo as new. |
| `~/Library/Logs/LightroomSync/sync.log` | What every check did, photo by photo. *Open log* opens it. |
| macOS user defaults | The saved settings |

The panel itself stays short: a status line for what the app is doing and what the last check did, the settings, and the actions. The detail goes to the log. While a check runs, the menu bar icon turns.

### Diagnostics

`lrsync-check` prints what the app sees for a share link, and can download the photos to a folder, without touching Photos:

```sh
swift run lrsync-check "https://adobe.ly/xxxxxxx"
swift run lrsync-check "https://adobe.ly/xxxxxxx" ~/Desktop/lightroom-test
```

It reports each photo's size, whether Lightroom holds edits for it, and the name the app would look for in Photos. Use it when a share link does not behave as expected.

## How it works

Adobe's official Lightroom API is not usable for this: the Firefly Services "Lightroom API" reached end of life on July 31, 2026, and the older partner catalog API is invitation-only with full-size renditions gated behind a scope Adobe grants by hand. Lightroom desktop has no plugin, AppleScript or Shortcuts support either. See [docs/research.md](docs/research.md) for the details and sources.

What does work, and what this app uses, is the web gallery of a shared album. Its page talks to these unauthenticated endpoints:

```
GET https://lightroom.adobe.com/v2c/spaces/{shareID}                       share settings (downloads on/off)
GET https://lightroom.adobe.com/v2c/spaces/{shareID}/resources             the albums in the share
GET https://lightroom.adobe.com/v2c/spaces/{shareID}/albums/{albumID}/assets?embed=asset
                                                                           photos with timestamps, edit state, file names
GET https://dl.lightroom.adobe.com/spaces/{shareID}/assets/{assetID}       full-size edited JPEG (403 when downloads are off)
```

The last call is exactly what the gallery's *Download* button does. For photos whose originals live in Lightroom's cloud it returns a JPEG at the edited photo's full pixel size, with EXIF, XMP and the ICC profile embedded. Photos that only reached the cloud as smart previews (synced from Lightroom Classic) come back at 2048 px; the app imports them anyway and logs a warning.

On the Mac side the app imports each file with PhotoKit (`PHAssetCreationRequest`), sets the capture date, adds it to the chosen album, and records the Photos identifier in the ledger. Before importing, it looks for an existing asset with `PHAsset.fetchAssets` narrowed by creation date, comparing each candidate's original file name from `PHAssetResource`.

## Limits

- **These endpoints are not documented by Adobe** and could change. The app fails loudly, in the menu bar icon and the log, rather than doing something odd if the responses stop making sense.
- **Sharing by link means anyone with the link can view and download the album.** The link is unguessable, but treat it as a secret. Invite-only shares cannot be read without an Adobe login.
- Photos synced to Adobe's cloud from Lightroom Classic exist there only as smart previews, so they arrive at 2048 px on the long edge.
- You get a rendered JPEG, not the RAW original. Videos and Live Photos are skipped.
- The app polls with one small JSON request per interval, and only contacts the download host for new photos. The default is every 15 minutes; the control accepts up to 240 minutes, 48 hours or 30 days.
- Not affiliated with, or endorsed by, Adobe or Apple.

## Project layout

```
Sources/LightroomSyncCore    platform-independent logic: share-link parsing, gallery client,
                             sync policy and settings, ledger, engine. Builds and tests on Linux too.
Sources/LightroomSync        the macOS menu bar app (SwiftUI MenuBarExtra + PhotoKit)
Sources/lrsync-check         command-line diagnostics
Tests/LightroomSyncCoreTests unit tests, with captured (anonymized) gallery responses as fixtures
Resources/AppIcon.icns       the app icon, generated by scripts/make-icon.py
scripts/                     Info.plist, the .app bundling script, the test runner, the icon generator
docs/research.md             why this approach, with sources
```

## Licence

[MIT](LICENSE).
