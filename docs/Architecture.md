# Processing decisions

The initial directory was empty. Development proceeded through building the foundation, passing photo tests, passing SDR export tests, implementing/validating HDR, implementing StoreKit/trial, and running integration/UI QA.

| Directory | Responsibility |
|---|---|
| App | Main-actor editor lifecycle and observable state |
| Models / Import | File transfer, temporary ownership, actual AVAsset inspection |
| Processing | Shared color engine, fixed clip analysis, player filtering, HDR policy |
| Export | Sequential reader/writer, original audio packets, options, validation, Photos save |
| Commerce | Verified StoreKit ownership and durable Keychain trial reservation |
| Views | Native home, editor, export and purchase screens |

## Color

A reused Metal-backed CIContext works in extended linear Rec.2020 with half-float intermediates. Photos retain wide color through processing and are converted to Display P3 at JPEG output. Orientation is baked and EXIF orientation normalized.

The automatic estimator samples a small float thumbnail, omits very dark/bright values, measures channel imbalance, luminance distribution and saturation, and bounds restoration. Red reconstruction is a convex combination of existing channels rather than a large red multiplier. Neutral whites remain neutral under red restoration. Presets use conservative vibrance and warmth. Intensity dissolves the complete original/corrected results, with exact zero/original behavior.

Video analyzes ten evenly spaced samples from 10% to 90% of the clip, rejects scene outliers, and averages the retained samples into one constant scene plan. Preview and sequential export share this plan, including a uniform 2x2 depth map. This deliberately prioritizes short processing times and consistent colour for recreational dive clips over adaptation to changing scenes. If no retained sample has a usable depth fit, both paths use the legacy colour correction; rejected samples must never supply a replacement physical plan.

Device and source profiles select the initial analysis compute policy and retained depth-map size. The policy cadence fields and environment-change detector are not used for per-frame analysis in the current export path. No per-frame depth inference or optical flow is performed, and analysis policy never changes output resolution, frame rate or SDR/HDR selection. Restoration confidence and per-channel recoverability bound the physical contribution independently of device performance.

Water toning uses a gradual redness transition. Chroma-based subject protection fades out in low-chroma, murky water, where small compressed colour differences cannot reliably distinguish water from a subject. Strongly coloured water still protects less colourful subjects such as silver fish. This is part of the existing colour kernel, with no added inference, blur pass or frame buffer.

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
