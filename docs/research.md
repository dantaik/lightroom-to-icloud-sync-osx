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
| Reading the local `.lrlibrary` package | Cannot render edits | It holds originals, smart previews and develop settings; producing an edited export needs Adobe's rendering engine. |
| UI scripting via Accessibility | Possible but brittle | Would drive the Export dialog; breaks with every UI change. |
| **Web gallery endpoints of a shared album** | **Used** | Unauthenticated, same calls the gallery page makes, full-size edited JPEG available when the owner enables *Allow downloads*. |

## The shared-album endpoints

The share page `https://lightroom.adobe.com/shares/{shareID}` embeds a config with `"base": "https://photos.adobe.io/v2/"` and calls these, all without credentials:

- `GET https://lightroom.adobe.com/v2c/spaces/{shareID}` → `payload.download` (bool), `payload.private`, `createdOnClient`.
- `GET https://lightroom.adobe.com/v2c/spaces/{shareID}/resources` → albums with `payload.name` and a `/rels/space_album_images_videos` link.
- `GET https://lightroom.adobe.com/v2c/spaces/{shareID}/albums/{albumID}/assets?embed=asset&subtype=image%3Bvideo&limit=500` → album entries; each has `payload.userCreated` (when added), and an embedded `asset` with `payload.captureDate`, `payload.userUpdated`, `payload.develop` (`croppedWidth/Height`, `userUpdated`, `xmpCameraRaw` when edited), `payload.importSource` (`fileName`, `originalWidth/Height`, `sha256`) and rendition links (`/rels/rendition_type/2048`, `1280`, `640`, `thumbnail2x`, sometimes `/rels/rendition_generate/fullsize`). Pagination via `links.next.href`, relative to `spaces/{shareID}/`.
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
