<img src="docs/app-icon.png" alt="" width="104" align="left">

# Lightroom Sync

**A macOS menu bar app that copies a shared Lightroom album into iCloud Photos.**
JPEGs with your edits applied, at a size you choose, each photo synced once and never again.

<br clear="left">

[![CI](https://github.com/dantaik/lightroom-to-icloud-sync-osx/actions/workflows/ci.yml/badge.svg)](https://github.com/dantaik/lightroom-to-icloud-sync-osx/actions/workflows/ci.yml)

Lightroom Sync watches one album in **Lightroom** (the cloud-based Lightroom, not Lightroom Classic) and adds every photo in it to the Photos library on your Mac, as a JPEG with your edits already applied. By default each photo is 6016 pixels on the long edge, which fills a Pro Display XDR pixel for pixel; [two smaller sizes and the uncapped original](#photo-size) are a menu away. With iCloud Photos enabled, Photos uploads it like any other picture, so the album reaches your iPhone and iPad.

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

`make app` compiles a release build, assembles the `.app` bundle with its icon and `Info.plist`, and signs it ad hoc. There is nothing to configure. One dependency is fetched on the first build: Apple's [swift-crypto](https://github.com/apple/swift-crypto), for the SHA-256 behind the duplicate check. It is used on Linux as well as macOS, where CryptoKit is not available.

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

Every push and pull request runs the same tests on both Linux and macOS through GitHub Actions, which also builds `LightroomSync.app` on macOS; see [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

### Regenerating the icon

The icon is committed twice: as `Resources/AppIcon.iconset`, which `make app` hands to macOS's own `iconutil`, and as `Resources/AppIcon.icns`, used only if `iconutil` is unavailable. Building needs no Python. If you change the artwork in `scripts/make-icon.py`, regenerate both with:

```sh
python3 -m pip install Pillow
python3 scripts/make-icon.py
```

**If the app shows a blank or generic icon**, macOS is almost certainly serving a cached one: it caches icons per bundle, and a bundle that once had no icon keeps showing the blank one. `make install` clears it for you, or do it by hand:

```sh
make refresh-icon        # touches the bundle, re-registers it, restarts the Dock
```

To confirm the icon really is in the installed bundle:

```sh
ls -l /Applications/LightroomSync.app/Contents/Resources/AppIcon.icns
plutil -extract CFBundleIconFile raw /Applications/LightroomSync.app/Contents/Info.plist
```

## Setting it up

1. **Share the album from Lightroom.** Open the album in Lightroom (desktop, web or mobile), choose *Share & Invite*, set *Link access* to **Anyone can view**, and under *Link settings* turn on **Allow downloads**. Copy the link; it looks like `https://adobe.ly/…` or `https://lightroom.adobe.com/shares/…`.
2. Click the menu bar icon and paste the link into *Lightroom album share link*.
3. Optionally name a **Photos album**. The app creates it if it does not exist. Leave it empty to add photos to the library only.
4. Choose a **Photo size**. Large is the default; see [Photo size](#photo-size). **Fetch at once**, in the section below it, decides how many photos are downloaded in parallel; 5 is the default and is usually right.
5. Set **Check every** to a number and a unit: minutes, hours or days. Turn on **Start at login** if you want it running all the time.
6. Press **Save**. The app then reads the album and confirms its name and that downloads are allowed.

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

- A photo becomes eligible once it has been in the shared album for at least the check interval, up to a limit of 15 minutes. That leaves you time to finish your first edits before the version is captured, without a long interval also becoming a long delay: checking once a day means looking once a day, not holding every new photo back for a day.
- A photo edited within the last two minutes waits for the next check, so an edit in progress is not captured half done.
- Once synced, a photo is recorded in a local ledger and is **never synced again**, however often it is edited later. Removing it from the Lightroom album or from Photos does not resync it.
- If the same photograph appears twice in the album, it is imported once. Three things can say it is the same one, and the second copy is recorded against the photo already in Photos rather than imported again:
  1. **The original's hash**, as Lightroom reports it in the album listing. Free, and settles the question before anything is downloaded.
  2. **The same original file name within a day of the same capture time** — the match the Photos lookup makes against the library. Also free, and it covers the assets Lightroom reports no hash for, or a different hash for each copy.
  3. **The picture's own hash**, if it gets that far: a SHA-256 of the downloaded JPEG with every metadata segment left out, so two copies match however differently they are described, and whatever their file names. This one costs a download to reach, so it saves the duplicate in Photos rather than the work — but it is the only one that can compare the photographs themselves. See [The content hash](#the-content-hash).
- Once a photo is eligible, and before downloading it, the app asks Photos whether it is already there. See [Using two Macs](#using-two-macs). The waiting rules are applied first, because that lookup searches the library around the photo's capture date and a photo that is not eligible yet would pay for one on every check until it was.
- The configured Photos album is repaired, not just filled. See [The Photos album](#the-photos-album).
- **Sync now** checks immediately and ignores both delays.
- While a check is running the Mac is kept awake, so a pass is not cut in half by the machine dozing off between one photo and the next. Only idle system sleep is held back, and only until the check finishes: the display still sleeps on its own schedule, closing the lid or choosing Sleep still sends the Mac to sleep, and on battery macOS may sleep through a check regardless. A pass cut short that way costs nothing but the work it had done; the next check picks those photos up again.
- Videos are listed but skipped. Only photos are synced.
- Each photo is capped at the [photo size](#photo-size) you chose, 6016 px on the long edge by default.
- Each photo keeps what Lightroom knows about it. See [Metadata](#metadata).

### Photo size

A full-size render from a modern camera is 40–60 megapixels and 20–30 MB. That is more than any screen can show, and it is what makes a sync slow: Lightroom builds the file on demand, then Photos has to carry it up to iCloud and down onto every device. The **Photo size** menu caps the long edge instead.

| Size | Long edge | What it is for |
|---|---|---|
| **Large** (default) | 6016 px | A Pro Display XDR is 6016 × 3384, so a landscape photo is a desktop background for it with nothing scaled. Native on every smaller display too. |
| **Medium** | 3840 px | 4K. Native on any display but the XDR, at a quarter of Large's pixels. |
| **Small** | 2048 px | Plenty for an iPhone or iPad. **By far the quickest**, because Lightroom already holds a 2048 px rendition: nothing full-size is downloaded at all. |
| **Original** | — | Every pixel Lightroom renders, which is what the app did before sizes existed. |

Large, Medium and Original come from the same full-size download. Large and Medium are then scaled down on your Mac with ImageIO, which keeps the EXIF, the XMP and the colour profile, and re-encodes at JPEG quality 0.9. A photo that is already smaller than the size you picked is imported exactly as it arrived, never re-encoded and never enlarged.

Changing the size affects photos synced from then on. A photo already in the ledger is never synced again, so it stays at the size it was imported at.

### Fetch at once

Lightroom builds each full-size photo when it is asked for, so a check spends nearly all of its time waiting rather than working — on a large album, hours of it. **Fetch at once** (1–10, default 5) sets how many photos are downloaded in parallel, which overlaps that waiting. On a backlog it is close to a straight division: five at once finishes in about a fifth of the time.

Only the fetching is parallel. Importing into Photos and writing the ledger stay strictly one at a time and in order, because Photos serializes its own changes anyway and the ledger is a single file rewritten whole — and because the duplicate checks read the ledger before acting on it, so running them in parallel could import the same photograph twice.

For the same reason, two photos that would answer each other's duplicate check are never fetched at the same time: the second waits for the first to land and is then checked against it. Both identities count here, the file hash and the file name, since the entry that answers either one — and the photo the Photos lookup would find — only exists once a fetch has been imported.

Set it to 1 to turn the overlap off. Lower it if the log says Lightroom asked the app to wait before serving a photo: that means the share is being asked for more at once than it will give.

### The content hash

Lightroom's own `sha256` is the hash of the original *as it was imported*, and it arrives in the album listing — which is what makes it worth having: a duplicate it recognizes costs nothing, because nothing has been downloaded yet. But it is not always there, and not always the same for two copies of one photograph.

So once a photo has been downloaded, and just before it is handed to Photos, it is hashed again — this time by its picture alone. Every metadata segment is left out (`APP0`–`APP15`, holding JFIF, EXIF, XMP and the ICC profile, and `COM` comments); what is hashed is the frame, quantization and Huffman tables, the scan header and the entropy-coded picture. Two copies of one photograph therefore match however differently they are described, or not described at all, and whatever they are called. If the hash is already in the ledger, the download is thrown away and the asset is recorded against the photo already in Photos.

Two things this deliberately does not do:

- It does not save the download. The check needs the file, and Lightroom builds each full-size photo on demand — so this catches the photo arriving in Photos a second time, not the time spent fetching it.
- It does not carry across a change of [photo size](#photo-size). The same photograph at 2048 px and at 6016 px is not the same file, so not the same hash. The two checks above still apply.

A file that does not parse cleanly as a JPEG simply has no content hash, and falls back on the checks that need none.

### Metadata

A photo should arrive in Photos described the way it is described in Lightroom, so it turns up in a search for the lens you shot it with and sits in the right place on the map. The full-size download already carries most of that in its EXIF and XMP. The 2048 px rendition behind **Small** does not reliably: it is a preview Adobe generated, and what survives in it is Adobe's business. So the app carries the album listing's own copy of the metadata and fills in whatever the file is missing, at every size.

| What | Where it ends up |
|---|---|
| Capture time | The photo's date in Photos, and `DateTimeOriginal` in the file |
| Place | The Photos map and Places, and the GPS tags in the file |
| Camera, lens, ISO, aperture, shutter, focal length | The Info panel in Photos, from the file's EXIF |
| Caption | The caption of the Photos asset, and IPTC in the file |
| Title, keywords, creator, copyright | IPTC and XMP in the file |
| 4 or 5 stars | A **Favourite** in Photos |

What the file already says wins: what a camera wrote into the original is a better account of the photo than Adobe's JSON copy of it, so only the gaps are filled. Writing them does not re-encode the image, so it costs no quality. Titles and keywords stay in the file rather than reaching Photos itself — PhotoKit can set a photo's date, place and favourite flag, and nothing else — so Photos shows the caption but not the keywords, and both survive an export.

Only photos synced from now on are described this way. A photo already in the ledger is never synced again, so it keeps the metadata it was imported with.

#### Capture time and time zones

Lightroom reports a capture time the way EXIF does, as a wall-clock reading with no time zone: `2024-09-18T15:55:12` is a quarter to four in the afternoon, but not *where*. Read in whichever zone the syncing Mac happens to be in, a photo shot in Tokyo and synced from California lands eight hours out.

The downloaded file usually knows better, because EXIF 2.31 records the zone the camera was set to in `OffsetTimeOriginal`, so that is what the capture time is read in when the file carries it. Without it there is nothing better to go on than the Mac's own zone, which is what the app has always used. `lrsync-check` prints `(no zone; read in this Mac's)` for the photos where this applies.

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
- Quitting mid-check is safe. Each photo is recorded as it is imported, so the next check carries on from there; part-finished downloads are thrown away and fetched again. A photo that reached Photos just before the app quit is found there by the next check and recorded without being downloaded again.

A photo without a capture date is not looked up at all, since the search would have to scan the whole library; it is simply downloaded. If the Photos check fails (no permission, for example), the app logs a warning and syncs the photo: a duplicate is better than a photo that never arrives. The ledger makes the same name-and-capture-time match on its own record first, so a photograph this Mac has already synced is still caught when the library cannot be searched.

## Where things are kept

| Path | What |
|---|---|
| `~/Library/Application Support/LightroomSync/ledger.json` | The record of synced photos. Delete it to make the app treat every photo as new. |
| `~/Library/Application Support/LightroomSync/downloads/` | Photos being fetched right now. Nothing here is worth keeping: each check clears out whatever an interrupted one left behind. |
| `~/Library/Logs/LightroomSync/sync.log` | What every check did, photo by photo. *Open log* opens it. |
| macOS user defaults | The saved settings |

The panel itself stays short: a status line for what the app is doing and what the last check did, the settings, and the actions. The detail goes to the log. While a check runs, the menu bar icon turns and a bar under the status line follows it.

A check does not reach the photos straight away: it has the share link to follow, the share to read, the album to page through, and the Photos album to put anything back into — which, on the first check after the app starts, is also where macOS asks for permission to the Photos library. None of that says in advance how long it will take, so until the photos have been counted the bar runs without a value and the status line names the step it is on: *Opening the share link…*, *Reading the share…*, *Listing the album…*, *Checking the Photos album…*, *Clearing unfinished downloads…*. Once the album has been listed the bar counts the photos off instead.

### Diagnostics

#### Why a check was slow

Every check times itself, so a slow one says which step was slow rather than leaving it to be guessed at. Each photo carries its own breakdown, and the check ends with the totals and, when one step dominated, what that step is:

```
Album “Shared”: 4 photos, 4 not yet synced, at 6016 px (listed in 3 ms)
Synced DSC_3921.NEF (6016×3996) in 1.11 s — lookup 700 ms, download 402 ms, resize 1 ms, ledger 2 ms
Waiting on DSC_4000.NEF: added 0 min ago, eligible in 15 min
Pass took 3.32 s: Photos lookups 2.10 s (×3), downloads 1.21 s (×3), ledger 5 ms, listing 3 ms, resizing 3 ms
Most of that was Photos lookups (63%): every photo not yet in the ledger is searched for across the
library by capture date, which costs more the larger the library is.
```

The steps are `listing` (reading the share and paging the album), `refiling`, `Photos lookups`, `downloads`, `resizing`, `metadata`, `imports` and `ledger`. Anything under a millisecond is left out. Because photos are fetched several at a time, the per-photo times can add up to more than the pass took.

If `downloads` dominates, there are two levers: raise [**Fetch at once**](#fetch-at-once) to overlap more of the waiting, or drop the [photo size](#photo-size) to **Small**, which takes a rendition Lightroom already holds and downloads nothing full-size.

#### lrsync-check

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
GET https://lightroom.adobe.com/v2c/spaces/{shareID}/{rendition href}      an edited JPEG Lightroom already holds: 2048, 1280, 640
```

The download call is exactly what the gallery's *Download* button does. For photos whose originals live in Lightroom's cloud it returns a JPEG at the edited photo's full pixel size, with EXIF, XMP and the ICC profile embedded. Photos that only reached the cloud as smart previews (synced from Lightroom Classic) come back at 2048 px; the app imports them anyway and logs a warning.

The rendition call is what the gallery shows on screen. Each asset in the listing carries a `/rels/rendition_type/2048` link, and the file behind it is already built, so the **Small** size skips the download host altogether and arrives in a fraction of the time. Nothing above 2048 px is offered that way, so the larger sizes take the full-size download and are scaled down on the Mac. A rendition that cannot be fetched is not fatal: the app logs it and falls back to the full-size download.

The album listing also carries the photo's `payload.xmp` (the original's XMP packet, by namespace), `payload.location` and `payload.ratings`. That is where the [metadata](#metadata) comes from for a photo whose file arrived without it.

On the Mac side the app imports each file with PhotoKit (`PHAssetCreationRequest`), sets the capture date, the location and the favourite flag, adds it to the chosen album, and records the Photos identifier in the ledger. Before importing, it fills the gaps in the file's own EXIF, IPTC and GPS with ImageIO, copying the compressed image across untouched rather than re-encoding it. Before all that, it looks for an existing asset with `PHAsset.fetchAssets` narrowed by creation date, comparing each candidate's original file name from `PHAssetResource`.

## Limits

- **These endpoints are not documented by Adobe** and could change. The app fails loudly, in the menu bar icon and the log, rather than doing something odd if the responses stop making sense.
- **Sharing by link means anyone with the link can view and download the album.** The link is unguessable, but treat it as a secret. Invite-only shares cannot be read without an Adobe login.
- Photos synced to Adobe's cloud from Lightroom Classic exist there only as smart previews, so they arrive at 2048 px on the long edge whatever size you choose. The log says when that happens.
- You get a rendered JPEG, not the RAW original. Videos and Live Photos are skipped.
- Photos can be given a date, a place and a favourite flag through PhotoKit, and nothing else. A title or a keyword can only travel inside the file, where Photos does not show it.
- A photo synced at one size is never synced again at another; the ledger has already recorded it.
- The app polls with one small JSON request per interval, and only contacts the download host for new photos. The default is every 15 minutes; the control accepts up to 240 minutes, 48 hours or 30 days.
- The app cannot sync while the Mac is asleep, and it does not wake it to check. It holds sleep off for the length of a check it has already started; checks that came due while the Mac slept run within twenty seconds of it waking.
- Not affiliated with, or endorsed by, Adobe or Apple.

## Project layout

```
Sources/LightroomSyncCore    platform-independent logic: share-link parsing, gallery client,
                             sync policy and settings, ledger, engine. Builds and tests on Linux too.
Sources/LightroomSync        the macOS menu bar app (SwiftUI MenuBarExtra + PhotoKit,
                             ImageIO for scaling photos down and for writing their metadata)
Sources/lrsync-check         command-line diagnostics
Tests/LightroomSyncCoreTests unit tests, with captured (anonymized) gallery responses as fixtures
Resources/AppIcon.icns       the app icon, generated by scripts/make-icon.py
scripts/                     Info.plist, the .app bundling script, the test runner, the icon generator
docs/research.md             why this approach, with sources
```

## Licence

[MIT](LICENSE).
