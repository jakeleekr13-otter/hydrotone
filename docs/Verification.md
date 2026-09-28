# Pending verification

This page lists the checks that are still open. The product owner decided to finish the implementation first and run every check in one final round (25 Sep 2026). Each change already has its own unit tests.

## Open work (do first)

- **The three built-in presets look almost the same.** The product owner found this on the iPhone on 25 Sep 2026. The preset tuning (`e02c19e`) made each preset match its name, but it kept the changes small to stay inside the guards. Next: make Natural, Tropical and Deep Dive clearly different at the default intensity, then check them with the other presets items below.

## Changes waiting for the final round

| Commit | Change |
|---|---|
| `a439df0` | Highlight shoulder: highlights roll off instead of clipping |
| `13ffbee` | Custom user preset: five saved sliders for photo, batch and video |
| `e02c19e` | Tropical and Deep Dive tuned to match their names |
| `7651372` | Custom Saturation and Temperature made visible (wider ranges) |

## Long-video notice (28 Sep 2026)

A video of 45 s or more shows "Analysis and correction can take longer for longer videos." above "Analyzing…" (`EditorModel.longVideoSeconds`).

Checked on the iPhone 17 simulator (iOS 27.0), in Korean, with a 50 s clip: the notice showed above "분석 중…".

Still open:
- A video shorter than 45 s shows no notice.
- The same check on the iPhone, and in landscape.

## Share sheet opens MarineLens (28 Sep 2026)

The extension opens `marinelens://share` after the copy, through the `UIApplication` object on its responder chain.

Checked on the iPhone 17 (iOS 27.0) with a temporary UI test: Photos → Share → MarineLens.

| Shared item | MarineLens came to the front | Editor |
|---|---|---|
| 1 video (14 s) | Yes | Opened, showed "Analyzing…" |
| 1 photo | Yes | Opened with the preview and Natural Dive selected |

Still open:
- Several photos: MarineLens opens on the batch screen.
- A partial share: the sheet stays with the note and the Open MarineLens button, and the button opens MarineLens.
- Share while the editor is open: MarineLens comes to the front on that editor, and the share opens after going back.
- App Review: Apple's extension guide lets only a Today widget open its app. If review objects, remove the open call. The share then waits for the next launch, as before.

Device check note: `xcodebuild test` on the iPhone left the old share extension installed. Install with `xcrun devicectl device install app` before a share-sheet check.

## Video export keeps the source timescale (28 Sep 2026)

The iPhone rejected the export of `problem_video/cannot export/2019-05-05 18.37.02.MOV`: "frames read back 1755 vs written 1756". The writer rounded times to 1/600 s. The last frame starts 0.63 ms before the end, so it moved onto the end of the edit. The file held that frame but never showed it. Video export now writes in the source track's timescale.

Checked:
- Simulator: `VideoTests.testLastFrameJustBeforeTheEndIsShown` failed with invalidOutput before the change and passes after it.
- Mac copy of the export path, on the real clip: 1756 frames written, 1756 decoded after the change (1755 before).

Still open:
- Export the same clip on the iPhone.

## Import, share sheet and file names (28 Sep 2026, `4aaa7cc`)

Built for the simulator. These unit tests pass: ExportNamingTests, FileImportTests, PhotoTests, LocalizationTests and BatchTests. FileImportTests uses a RAW sample from DeveloperMedia.

On the simulator, a share placed in the App Group inbox opened in the editor at launch. The extension UI itself was not run. Nothing below was checked on an iPhone yet.

- **Signing: done on 28 Sep 2026.** Automatic signing registered `com.marinelens.app.share` and the App Group `group.com.marinelens.app`. The device build embeds a development profile with the App Group in the app and in the extension. The App Store profile is created again at the next archive.
- **Share sheet in Photos.** MarineLens appears in the app row for 1 photo, 10 photos and 1 video. It does not appear for 11 photos or 2 videos. After "Added to MarineLens", MarineLens opens by itself, and the share opens in the editor or the batch screen.
- **Share edge cases.**
  - A Live Photo opens as the still photo.
  - Share while the editor is open: nothing replaces it; the share opens after going back.
  - Free user shares 5 photos: only the first opens, with the Pro notice.
  - Share a RAW (DNG) from Photos and a file from the Files app.
- **Import from Files.** HEIC, JPEG, iPhone ProRAW DNG, one other camera RAW (ARW/CR3/NEF), MOV and MP4. Include one iCloud Drive file that is not downloaded yet.
- **File names in Photos.** Check the name in the photo's info panel after saving:
  - From Files and the share sheet: `<original>_MarineLens_<look>.jpg` (or `.heic`).
  - From the Photos picker: it depends on the file name the picker delivers. If the picker gives a temporary name, the time-based fallback name appears. Record which one.
- **RAW on the device.** `CIRAWFilter` decodes the RAW file again for each preview render. Measure preview speed, export time and memory for a RAW of 20 MP or more.
  - Keep the RAW path on `CIRAWFilter`. On the simulator, `CIImage(contentsOf:)` returned only the 1616 px embedded preview.

## Photo output formats (28 Sep 2026)

JPEG now saves at quality 1. 10-bit HEIC is a new choice. PhotoFormatTests, PhotoTests, PhotoHDRTests, BatchTests, CustomPresetTests, ExportNamingTests and LocalizationTests pass on the simulator. PhotoFormatTests and PhotoHDRTests also pass on the iPhone 17, including the HDR HEIC gain map. Nothing below was checked by hand yet.

- **Export sheet.** The Format picker shows JPEG and HEIC. The note under it changes with the choice. The choice is kept for the next photo.
- **Batch screen.** The format menu next to Compare matches the export sheet. Save All writes the chosen type.
- **Photos.** A saved HEIC opens in Photos and the info panel shows `.heic`. An HDR photo saved as HEIC shows HDR in Photos.
- **Sharing a HEIC out.** Send one to a non-Apple app, such as a messenger. Record whether it arrives as HEIC or JPEG.
- **Size, time and memory on the iPhone.** Export a 20 MP ARW and a 48 MP iPhone photo in both formats. Record file size and export time, and watch for memory warnings. The Mac sizes are in [Architecture](Architecture.md).

## Colour tuning against AquaColorFix (28 Sep 2026)

The colour rules changed to move toward the AquaColorFix look ([benchmark](AquaColorFixBenchmark.md)). Run again before release:

- **Holdout.** Not run after this change. The last value (20.12 combined, 20.10 uniform) is from `6fd84cf`.
- **Presets on the new colour.** Tropical and Deep Dive were not re-checked. The Natural Dive pin in `PresetTests` was regenerated; that is the product change.
- **Market pairs by eye.** m1 and m4 lost about 1.5 ΔE against their targets and m2 lost 3.9 (its mid-tones are darker than the target). The AquaColorFix gate gained 8.2. Decide by eye which look the product wants on m2 (a dark, murky turtle scene).
- **Custom sliders.** The tone values under the sliders changed (shadow lift, highlight compression). Re-measure the caps in `CustomAdjustments.Caps`.
- **Real video.** The subject light removal and the trusted blue reference were not seen on video. Watch a bright fish or diver against blue water for a warm flicker.
- **Fine detail layer on the iPhone (28 Sep 2026, `07c004d`).** The harness judges a 960 px render; a full-size export has a 7.6 px blur radius. Check on a photo export at 100%: the mola or a fish body is crisper, its outline has no halo, open water shows no new grain. Check Custom Clarity at +100 on a dark, noisy photo (the noise floor does not scale with the slider). Check one real clip for shimmer in textured areas; the fix if it shows is a higher floor per clip. Export time on a 4032 px photo is unmeasured.
- **Depth model on Core AI.** iOS 27 ships `CoreAI.framework` (`AIModel`, `InferenceFunction`, `.aimodel`), and `apple/coreai-models` has a Depth Anything **v3 small** export (float32). Our depth model is Depth Anything v2 small fp16 on Core ML. Nothing in the app's colour path uses a model; only `DepthEstimator` would change. Decide later whether to add an iOS 27 path; it needs a new depth-quality and holdout measurement, because the model is different.
- **Video: values that follow the light.** Today a clip gets one set of values from 10 samples. So a clip whose light changes is right in some parts and wrong in others (the product owner, 28 Sep 2026). The analysis is a 48x48 statistic and needs no model. It can run on every frame or every few frames and be smoothed over time before `make()`. Only the depth model is costly, and the record says per-pixel depth did not help video. Design this as its own step. It changes `VideoRestorationAnalysis`, not the colour rules.

## HDR photo export (28 Sep 2026)

Checked:
- iPhone 17, PhotoHDRTests (3 of 3 pass). A synthetic HDR photo (headroom 4) exported as a JPEG with an ISO gain map. The output headroom was 4.0 and the highlights reached 4.5. The SDR image in the file matched the normal SDR export (average and maximum).
- Simulator: 22 affected unit tests pass. The end-to-end HDR test skips there, because the simulator opens every gain-map photo with headroom 1.

Still open, on the iPhone:
- A real iPhone HDR photo: Export shows SDR/HDR with HDR selected for Pro. The saved photo looks brighter in Photos than an SDR save of the same edit. Colours match between the two saves.
- Memory and time for a 48 MP HDR photo. HDR export renders the full image twice (SDR and HDR).
- The batch screen with a mix of HDR and SDR photos.
- An iPhone without an HDR display: it is unknown whether photos read with headroom above 1 there.
- Live Photos: by decision (28 Sep 2026), a Live Photo imports and exports as its still photo. The motion is not kept, because underwater Live Photos are rare. Check that a Live Photo imports as its still photo from the picker, the share sheet and Files.

## User-facing name is MarineLens (28 Sep 2026)

The app, share sheet, UI text in all 5 languages, export file names, and App Store text now say MarineLens. Bundle IDs, `com.marinelens.pro`, the App Group, the keychain service, the `marinelens://` scheme, and target names stay MarineLens.

Checked: the built app and share extension both have `CFBundleDisplayName = MarineLens`. ExportNamingTests, DiagnosticsTests and PhotoFormatTests passed on the simulator.

Still open:
- The home screen and share sheet on the iPhone show MarineLens.
- Run `scripts/make_app_store_screenshots.swift` again. The PNGs in `AppStoreAssets/Screenshots/` still say MARINELENS.
- `AppStoreAssets/IAP/MarineLensPro-1024.png` may show the old name. Check it and redraw it if needed.
- The support and privacy pages (`marinelens-support` repo) still use the old name.
- Trademark check for MarineLens: USPTO class 9, KIPRIS. Then check that the name is free in App Store Connect.
- `scripts/generate_localizations.py` is stale. Its output differs from the catalog by about 6,000 lines. Do not run it.

## Final round checklist

1. **Colour scorecard.** Run `scripts/color-eval/tune_eval.sh <name>`. Check every guard in [the harness README](../scripts/color-eval/README.md#guards-used-for-tuning).
2. **Holdout, once.** Run `scripts/color-eval/run_eval.sh <name>-holdout holdout:40`. The last value was 20.12 (combined) and 20.10 (uniform) at `6fd84cf`. It was not run after that.
3. **Presets.** The tuning round checked each preset at intensity 0.8, on photos only:
   - Tropical on shallow, bright scenes: r03, r08, r10, m5
   - Deep Dive on deep, dark-blue scenes: r02, r09, r11, r12, r13
   - Still to check:
     - UIEB dev and holdout for Tropical and Deep Dive
     - intensity values other than 0.8
     - by eye: do the presets differ enough to match their names? The differences are small.
     - Deep Dive's lavender sea fans on r11, and Tropical's peach sun core on r10
4. **Custom slider ranges.** The caps in `CustomAdjustments.Caps` were measured before the white reference and the highlight shoulder. Measure them again on the current code:
   - all five sliders at -1 and +1, at full strength
   - the joint budget for Brightness, Contrast and Saturation
   - Saturation and Temperature: on 25 Sep 2026 the product owner found Saturation very weak and Temperature not visible on the iPhone. `7651372` widened both. Check on the iPhone that both are clearly visible at ±50 and ±100, that + Temperature warms and - cools, and that water never turns neon, indigo or green.
   - one SDR clip and one HDR clip
5. **Real video on the iPhone.** Use 2 or 3 real dive clips, including 1 SDR and 1 HDR. Check:
   - colour stays stable from frame to frame
   - bright sand and the sun do not clip (the highlight shoulder)
   - neutral surfaces look grey (the white reference)
   - the Custom sliders change the preview and the export in the same way
   - HDR highlights stay above SDR white
6. **Full unit tests.** Run `xcodebuild test -scheme MarineLens -only-testing:MarineLensTests -skip-testing:MarineLensTests/PurchaseTests` on a simulator.
7. **UI tests.** Run `MarineLensUITests`. See the known failures below.
8. **Custom UI by hand.**
   - Custom sliders on a video. The simulator has no videos, so the UI test skips it.
   - Custom on the batch screen. The UI test needs Pro.
   - VoiceOver on a device.
9. **App Store text.** Update the preset descriptions after the preset check.

## Known issues to keep in mind

- **PurchaseTests hang on the simulator.** The StoreKit test session fails with `SKInternalErrorDomain Code=3`. It hung the same way at 14:51 on 25 Sep 2026, before any change on this list. Skip it on the simulator.
- **LongVideoTests can fail under load.** In one full run, the memory growth was 424 MiB against a 220 MiB limit. Another agent was running at the same time. Run alone twice, it passed with 134 MiB and 154 MiB.
- **UI tests that already failed at `6a850b4` on this simulator:**
  - `MarineLensUITests.testPhotoImportPresetsCompareExportSaveAndTrialGate`, lines 24–29
  - `MarineLensUITests.testVideoImportAndLandscapeEditor`: the picker shows "No Videos"
  - `AppStoreScreenshotTests.testPhotoBeforeAndAfter`, line 35
- **`xcodebuild test` can hang after the last test.** On 28 Sep 2026 the results were complete at 07:46, but the process was still running 10 minutes later. Read the log, then stop the process.
- **A build can rewrite `Localizable.xcstrings`.** It adds a space before every colon and auto-extracts keys. If `git diff --stat` shows thousands of changed lines, restore the file.

## Done on 25 Sep 2026

- The two device-only tests passed on an iPhone 17 (iOS 27.0):
  - `testBundledDepthModelProducesCompactFiniteDepth`: one depth inference took 32.6 ms
  - `testFiveFrameAnalyzerOnPhysicalDevice`: 14.1 s in total
- Unit tests at `e02c19e`: 127 run, 2 skipped (device only), 0 failed. An earlier full run failed only the LongVideoTests memory test, under load (see above).

## Ideas, not planned

- **Mac.** The project is iPhone only (`TARGETED_DEVICE_FAMILY = 1`). Mac support and Mac Catalyst are both off. The Processing code already runs on a Mac: the harness compiles it into a Mac tool. The smallest step is to run the iPhone app on Apple silicon Macs. It still needs a check of the photo picker, saving, StoreKit and video export on a Mac.
