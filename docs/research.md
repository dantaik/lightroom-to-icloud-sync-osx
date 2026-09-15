# Research notes: getting edited, full-size photos out of Lightroom (cloud)

Written September 2026 while deciding how to build this tool. Everything below was verified against live endpoints and public shares at that time.

## Goal

Sync the photos of one Lightroom (cloud) album to iCloud Photos from a background macOS app, using a high-resolution export with edits applied, without Lightroom Classic and without APIs that are deprecated.

## Options considered

| Route | Verdict | Why |
|---|---|---|
| Firefly Services "Lightroom API" | Dead | End of life July 31, 2026; required an enterprise contract; it was an image-operations API (auto tone, presets), not catalog access. [Deprecation notice](https://developer.adobe.com/firefly-services/docs/lightroom/getting-started/deprecation-announcement/), [auth requirements](https://developer.adobe.com/firefly-services/docs/lightroom/getting-started/) |
| Lightroom Partner (catalog) API, `lr.adobe.io/v2` | Not usable for an individual | Partner-only; basic access serves at most 2048 px renditions; `fullsize`/`2560` need the `lr_partner_rendition_apis` scope, which Adobe grants manually. A developer hit "Access is forbidden" until Adobe intervened. [Partner API repo](https://github.com/AdobeDocs/lightroom-partner-apis), [forum thread](https://community.adobe.com/t5/lightroom-ecosystem-cloud-based-discussions/issue-with-cloud-lightroom-api-generating-renditions/m-p/14266313) |
| Lightroom desktop app automation | None available | No plugin SDK, no AppleScript, no Shortcuts actions, no macOS share sheet. [Plugin request](https://community.adobe.com/t5/lightroom-ecosystem-cloud-based-ideas/p-3rd-party-plugin-support-for-lightroom-desktop-external-editors/idc-p/14940650), [share sheet request](https://community.adobe.com/feature-requests-681/p-add-macos-share-sheet-lightroom-desktop-660619) |
| Reading the local `.lrlibrary` package | Partly usable | Its originals cannot render edits — those are develop settings, and applying them needs Adobe's engine. Its `previews.noindex` renders *do* carry the edits, so they can replace a download up to the size they cover, which is screen-sized rather than full-size. The app prefers them under those rules; `lrsync-local` reports what a given library holds. |
| UI scripting via Accessibility | Possible but brittle | Would drive the Export dialog; breaks with every UI change. |
| **Web gallery endpoints of a shared album** | **Used** | Unauthenticated, same calls the gallery page makes, full-size edited JPEG available when the owner enables *Allow downloads*. |

## The shared-album endpoints

The share page `https://lightroom.adobe.com/shares/{shareID}` embeds a config with `"base": "https://photos.adobe.io/v2/"` and calls these, all without credentials:

- `GET https://lightroom.adobe.com/v2c/spaces/{shareID}` → `payload.download` (bool), `payload.private`, `createdOnClient`.
- `GET https://lightroom.adobe.com/v2c/spaces/{shareID}/resources` → albums with `payload.name` and a `/rels/space_album_images_videos` link.
- `GET https://lightroom.adobe.com/v2c/spaces/{shareID}/albums/{albumID}/assets?embed=asset&subtype=image%3Bvideo&limit=500` → album entries; each has `payload.userCreated` (when added), and an embedded `asset` with `payload.captureDate`, `payload.userUpdated`, `payload.develop` (`croppedWidth/Height`, `userUpdated`, `xmpCameraRaw` when edited), `payload.importSource` (`fileName`, `originalWidth/Height`, `sha256`), the photo's description (`payload.xmp` — the original's XMP packet by namespace: `dc`, `exif`, `tiff`, `aux`, `xmp`; `payload.location` in decimal degrees; `payload.ratings` keyed by Adobe user) and rendition links (`/rels/rendition_type/2048`, `1280`, `640`, `thumbnail2x`, sometimes `/rels/rendition_generate/fullsize`). Pagination via `links.next.href`, relative to `spaces/{shareID}/`.
- `GET https://lightroom.adobe.com/v2c/spaces/{shareID}/{rendition href}` → a rendition the gallery already holds, from the asset's `/rels/rendition_type/{2048,1280,640}` link. Already built, so it returns at once; used for the app's smallest photo size.
- `GET https://dl.lightroom.adobe.com/spaces/{shareID}/assets/{assetID}` → the file the gallery's Download button serves. The gallery bundle builds this as `dl.<host>/spaces/{space}/assets/{asset}` (and `…/albums/{album}/assets?fullsize=true` for a zip of the whole album).

Responses are prefixed with `while (1) {}` and must be stripped before JSON parsing.

## Verified download behavior

| Share state | Original in Lightroom | Downloaded |
|---|---|---|
| downloads on | 3052×4069 JPG, edited | 3052×4069 JPEG with EXIF, XMP, ICC |
| downloads on | 6016×4016 Nikon NEF, edited | 6016×4016 JPEG |
| downloads on | 9528×6328 DNG, edited (test album for this project) | 9528×6328 JPEG, 6–12 MB |
| downloads on | 2388×1668 PNG, cropped in Lightroom | 2005×1558 (the crop) |
| downloads on | photo synced from Lightroom Classic (smart preview only) | 2048 px, no `rendition_generate/fullsize` link |
| downloads off | any | HTTP 403 |

The 2048 px case matches Adobe's own documentation that Classic-synced photos are limited to smart-preview size. [Lightroom Queen on share settings](https://www.lightroomqueen.com/share-web-gallery-settings/)

## Prior art on GitHub

- [abstrctn/lightroom-album-import](https://github.com/abstrctn/lightroom-album-import): GitHub Action downloading 2048 px renditions of a public album via the same `v2c/spaces` endpoints; notes that 2560/fullsize are not available through the rendition links (true; the download host is the way).
- [russellramey/adobe-lightroom-automate-downloads](https://github.com/russellramey/adobe-lightroom-automate-downloads): browser-driven 2048 px downloader.
- [lou-k/lightroom-cc-api](https://github.com/lou-k/lightroom-cc-api): Python client for the partner API (needs Adobe approval).
- [sto3014/LRPhotos](https://github.com/sto3014/LRPhotos) and [halprin/lightroom-export](https://github.com/halprin/lightroom-export): Lightroom Classic → Apple Photos.
- [RhetTbull/osxphotos](https://github.com/RhetTbull/osxphotos) and [RhetTbull/photokit](https://github.com/RhetTbull/photokit): PhotoKit-based import into Photos from Python, with album and duplicate handling.

Nothing existing covered Lightroom (cloud) → iCloud Photos with full-size edited renders, hence this app.

## Apple side

`PHAssetCreationRequest` and `PHAssetCollectionChangeRequest` are available on macOS 10.15+ ([Apple docs](https://developer.apple.com/documentation/photos/phassetcreationrequest)). Importing into the System Photo Library with iCloud Photos enabled uploads to iCloud automatically. The app needs `NSPhotoLibraryUsageDescription` in its Info.plist, which is why it must run as an app bundle rather than a bare executable.

## Downloads that fail without an HTTP status

Observed on a real album in September 2026: eight full-size downloads, started over eight and a half minutes, all ended in the same second with `The network connection was lost.` (`NSURLErrorNetworkConnectionLost`, -1005). No HTTP status was ever served, so this is not any refusal Adobe can express — a share with downloads off answers 403, and a rate limit answers 429 or 503. Staggered starts and one simultaneous death mean one shared event rather than eight per-connection rejections.

Two things made it expensive rather than merely annoying, and both are now fixed:

- Nothing retried a transport error. Only 429 and 503 were retried; a `URLError` ended the photo, discarding however many minutes of on-demand rendering Adobe had already done. Nine photos and roughly eighty minutes of rendering were lost to an outage of about two minutes.
- `URLSessionConfiguration.timeoutIntervalForResource` was 15 minutes, and the longest download in that log ran 13 min 38.8 s — eighty seconds of headroom on a 60 MP raw.

Two app-side faults with the same fingerprint are worth ruling out before blaming a network:

- Saving settings mid-pass cleared the "a pass is running" flag, letting the scheduler start a second pass within 20 seconds. Two passes shared one ledger and one download directory, and sweeping that directory is among the first things a pass does.
- `httpMaximumConnectionsPerHost` defaults to 6. A "fetch 8 at once" setting therefore left two photos queued rather than transferring, with their timing clock already running — they read as slow downloads in the log rather than as photos that had not started.
