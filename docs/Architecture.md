# Processing decisions

The initial directory was empty. Development proceeded through building the foundation, passing photo tests, passing SDR export tests, implementing/validating HDR, implementing StoreKit/trial, and running integration/UI QA.

| Directory | Responsibility |
|---|---|
| App | Main-actor editor lifecycle and observable state |
| Models / Import | Photos picker, Files and share-inbox import, temporary ownership, actual AVAsset inspection |
| Processing | Shared color engine, fixed clip analysis, player filtering, HDR policy, HDR photo gain map |
| Export | Sequential reader/writer, original audio packets, options, validation, saved file names, Photos save |
| HydroToneShare (extension target) | Share sheet entry: copies shared items into the App Group inbox |
| Commerce | Verified StoreKit ownership and durable Keychain trial reservation |
| Views | Native home, editor, export and purchase screens |

## Color

A reused Metal-backed CIContext works in extended linear Rec.2020 with half-float intermediates. Photos retain wide color through processing and are converted to Display P3 at JPEG output. Orientation is baked and EXIF orientation normalized.

Analysis measures a small thumbnail: scene and water colour, bright near-neutral surfaces, red loss, luminance spread and saturation. `ColorCorrection.make` turns these into named values, and `FilterEngine` only applies them. `RestorationEngine.combined` removes the water veil with a depth-aware kernel, then applies the finishing values. Intensity and plan confidence blend the result, so a weak fit gives the plain correction. Photo, batch and video share this path; see [Colour algorithm](ColorAlgorithm.md).

Video analyzes ten evenly spaced samples from 10% to 90% of the clip, rejects scene outliers, and averages the retained samples into one constant scene plan. Preview and sequential export share this plan, including a uniform 2x2 depth map. This deliberately prioritizes short processing times and consistent colour for recreational dive clips over adaptation to changing scenes. If no retained sample has a usable depth fit, both paths use the legacy colour correction; rejected samples must never supply a replacement physical plan.

Device and source profiles select the initial analysis compute policy and retained depth-map size. The policy cadence fields and environment-change detector are not used for per-frame analysis in the current export path. No per-frame depth inference or optical flow is performed, and analysis policy never changes output resolution, frame rate or SDR/HDR selection. Restoration confidence and per-channel recoverability bound the physical contribution independently of device performance.

## Photo input and output

- JPEG, HEIC and the other ImageIO formats open with `CIImage(contentsOf:)`, expanded to HDR. All colour work then runs on the SDR tone-mapped image.
- Camera RAW opens with `CIRAWFilter`, at Apple's standard SDR rendering. On iOS, `CIImage(contentsOf:)` returned only the embedded preview (1616 px for a 5472 px ARW). The HDR-expanded path was also about 30% darker than the standard rendering.
- HDR photos can export as a JPEG with an ISO gain map. The SDR image in the file is the normal export.
- The HDR version (`PhotoHDR`) is that result times the source's ratio of HDR to tone-mapped SDR, in Rec.2020 luminance. The ratio never darkens and never exceeds the source headroom. So the colour engine never sees HDR values. The video HDR path is different: it filters the HDR frames directly.
- The HDR output check adds two tests: an ISO gain map is present, and the file reopens with headroom above 1.
- The simulator opens every gain-map photo with headroom 1. So HDR photo export can only be verified on an iPhone.
- Saved names come from `ExportNaming`: `<source>_HydroTone_<look>.<ext>`. Photos keeps the name through `PHAssetResourceCreationOptions.originalFilename`.
- Live Photos are treated as still photos. This is a product decision (28 Sep 2026).

## Import sources

- The Photos picker gives access to the picked items only.
- Files offers the types this device decodes, read at run time: `CGImageSourceCopyTypeIdentifiers()` for images (RAW included) and `AVURLAsset.audiovisualContentTypes` for movies. A coordinated read downloads an iCloud Drive file before the copy.
- Share sheet: a share extension can't open its app. So `HydroToneShare` copies each share into its own folder in the App Group container (`SharedInbox`). The folder stays hidden from the app until the copy is complete.
- The app opens the newest complete share when its home screen is visible. A newer share replaces an unopened one. An open editor is never replaced. A partial share older than one hour is deleted.
- Every source ends as a temporary copy that the app owns (`TemporaryFiles`). Then one rule set applies: one item opens the editor, and several photos open the batch screen (Pro). Videos open one at a time.

## Video

The exporter reads sequentially, renders into a reusable writer pixel-buffer pool, and releases each sample in an autorelease pool. It retains no array of video frames. Audio is passed through in its original compressed form with original timestamps and track count. If the output container cannot accept it, the operation fails instead of silently deleting audio. Orientation is baked into pixels; output transform is identity.

For HDR→SDR, AVAssetReaderVideoCompositionOutput uses an explicitly Rec.709 Apple composition with sourceTrackIDForFrameTiming, preserving variable timing. This avoids the direct PQ decoder-to-BGRA transfer failure observed on the simulator. The editor uses the same Apple SDR composition policy before shared filtering.

For HDR, decode stays in native 10-bit YUV. HLG stays HLG; PQ stays PQ. Pixel buffers and writer settings agree on transfer function, Rec.2020 primaries/matrix and HEVC Main10. HDR dynamic metadata insertion/preservation is disabled because pixel processing changes the image. Intermediate buffers are not converted to 8-bit. Automated tests verify that encoded highlights still exceed SDR reference white, not just that the container carries HDR flags.

Public Apple APIs can regenerate some Dolby Vision 8.4 metadata, but HydroTone deliberately does not enable or advertise this. Real Dolby Vision and external camera compatibility have not been certified. When Apple's decoder accepts compatible Dolby Vision HLG/PQ base layers, the output is plain HLG/PQ, or SDR.

After export the app checks codec, dimensions, orientation, duration, audio track count, transfer/gamut, HDR bit depth, encoded sample count and native-range decodability. Unit tests separately compare variable presentation timestamps and portrait pixels against the source. A successful writer completion alone does not expose a file to the user.

## Trial and lifecycle

A trial reservation is durably written before work begins. Successful validation commits consumption; failure/cancellation rolls it back. A pending reservation after a crash is refunded on the next launch because no deliverable was exposed. Keychain failure fails closed. No device fingerprinting is used.

Verified StoreKit purchase results, transaction updates and current entitlements control Pro ownership. Generation tracking prevents an older asynchronous entitlement read from overwriting a newer transaction update. Cancellation and pending approval do not unlock Pro.

Save requests add-only Photos permission. Denial retains the completed file for retry. Partial exports are removed after reader/writer cancellation; abandoned imports are cleaned after 24 hours. Storage is checked before import copying and export. Backgrounding cancels rather than claiming indefinite background execution.

## Apple references

API signatures/availability were checked against the installed SDK. Relevant public documentation:

- [Apple HDR and Dolby Vision AVFoundation guidance](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)
- [Editing HDR video with AVFoundation](https://developer.apple.com/videos/play/wwdc2020/10009/)
- [Core Image content headroom](https://developer.apple.com/documentation/coreimage/ciimage/contentheadroom)
- [Tone-map headroom filter](https://developer.apple.com/documentation/coreimage/citonemapheadroom)
- [Required-reason API declarations](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
