# HydroTone

Native iPhone underwater photo/video filters, targeting **iOS 26+**. SwiftUI, Core Image, AVFoundation, PhotosUI, StoreKit 2 and Keychain. No third-party runtime dependencies, accounts, uploads or analytics.

Open **HydroTone.xcodeproj**, select the **HydroTone** scheme and an iPhone simulator, then Run. For a physical iPhone, select your development team under Signing & Capabilities.

## Current behavior

- Import photos/videos with the system Photos picker; broad library access is not requested.
- Original, Natural Dive, Tropical and Deep Dive presets; 0–100% intensity and an explicit Compare control.
- Photo preview and export share the same engine. JPEG/HEIC input; full-resolution, orientation-normalized Display P3 SDR JPEG output. Capture dates are retained; stale thumbnails, gain maps and location metadata are not copied.
- Video V2 analyses 10 evenly spaced frames between 10% and 90% of the clip. It drops outlier samples, averages the rest into one filter, and applies that same filter to every frame. If no usable restoration plan remains, the clip falls back to the original HydroTone correction.
- Sequential GPU-assisted export preserves presentation timestamps and every supported audio track, supports source resolution/4K and optional 1080p without upscaling, and validates the output before offering Save to Photos.
- Export runs no depth inference. A cached device/source policy selects the analysis depth-map size. It does not change the requested resolution, frame rate or dynamic range. Optical flow is not enabled.
- SDR is the default. HDR sources are tone mapped by Apple's compositor for SDR output. HDR export preserves HLG or PQ in HEVC Main10 with Rec.2020 signaling. No Dolby Vision output claims are made.
- The video editor deliberately shows SDR, including a labeled tone-mapped preview for HDR sources. Native EDR preview and HDR photo output are unavailable.
- HDR export is offered only after a small actual export/validation succeeds for that source on the iPhone. Simulator UI conservatively disables HDR; the automated tests exercise the real 10-bit pipeline independently.
- Progress follows processed presentation time. Cancellation removes partial output. Backgrounding cancels the export, with a short background task reserved for cleanup.
- Free trial: **one photo export and one video export of the first 10 seconds**, up to 1080p SDR for video. No limit on importing or previewing. Failed/cancelled exports do not consume the trial. A validated, completed export consumes it; saving can be retried if Photos permission is denied.
- Pro: verified non-consumable **com.hydrotone.pro**, unlimited photos, full video length, source-resolution/4K and HDR where supported.
- English is the source and fallback language. The included String Catalog follows the iPhone language order and contains Korean, Japanese, Simplified Chinese and Traditional Chinese translations. The Translation framework is intentionally not used because HydroTone has fixed interface copy rather than user-generated text.
- Errors use privacy-safe Unified Logging and local MetricKit reports. Repeated events are aggregated and retained for seven days; nothing is uploaded automatically. The user can prepare, share or delete the report from Diagnostics.

## Purchases

Production ownership comes only from verified StoreKit transactions/current entitlements. Product prices come from `Product.displayPrice`.

Create `com.hydrotone.pro` as a non-consumable in your own App Store Connect application before testing real sandbox purchases. No App Store Connect account/product has been configured by this implementation.

`HydroToneTests/HydroTone.storekit` is a **local test configuration**. Its $4.99 price is test data, not a proposed or configured production price. Automated tests use `SKTestSession`. To try the local purchase screen manually, choose that configuration in the scheme's Run → Options → StoreKit Configuration. The default Run scheme uses the real StoreKit environment and does not grant mock Pro access.

## Build and test

Built using Xcode 27 / iOS 27 SDK, with deployment target 26.0 and runtime tests on iOS 26.2.

```sh
xcodebuild -project HydroTone.xcodeproj -scheme HydroTone \
  -destination 'platform=iOS Simulator,name=iPhone 16e,OS=26.2' \
  -derivedDataPath .build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

Simulator tests must be ad-hoc signed: unsigned app builds cannot exercise Keychain. For UI tests, put a photo and video in the simulator's Photos library and grant add-only Photos access to `com.hydrotone.app` (the UI suite exercises saving):

```sh
xcrun simctl addmedia booted /path/to/photo.jpg HydroToneTests/Fixtures/portrait_audio.mov
xcrun simctl privacy booted grant photos-add com.hydrotone.app
```

The app has a DEBUG-only launch argument for isolated real Keychain storage in UI tests. It does not bypass StoreKit verification and is excluded from Release.

Synthetic media fixtures are checked in. `scripts/make_test_media.py` regenerates the main codec/HDR fixtures using a developer-installed ffmpeg; ffmpeg is not included in the app. `scripts/create_project.py` reproducibly generates the Xcode project, whose source folders synchronize automatically. `scripts/make_icon.py` regenerates the wave icon.

See [QA matrix](docs/QA.md), [processing decisions](docs/Architecture.md), and [diagnostics review](docs/Diagnostics.md) for verification and remaining release checks.

The colour algorithm, its decisions and its evaluation are in [ColorAlgorithm](docs/ColorAlgorithm.md). The video pipeline is in [Video V2](docs/VideoV2.md). The scorecard harness is [scripts/color-eval](scripts/color-eval/README.md).
