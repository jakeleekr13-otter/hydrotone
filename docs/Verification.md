# Pending verification

This page lists the checks that are still open. The product owner decided to finish the implementation first and run every check in one final round (25 Sep 2026). Each change already has its own unit tests.

## Open work (do first)

- **Done (29 Sep 2026): distinguish the three built-in presets.** Jake checked the tuned presets
  (`8b9f278`) on the iPhone and accepted them. This closes the issue first reported on 25 Sep 2026.
  - 29 Sep 2026, tuned: Tropical moves 5.4 from Natural (was 4.0), Deep Dive 5.2 (was 3.2), median CIE76 on 26 images. Natural Dive is unchanged (pin test). Values and rejected tries: [ColorAlgorithm](ColorAlgorithm.md).
  - 29 Sep 2026, before tuning: Jake sees a slight difference on the iPhone. The code reads every preset value in `ColorCorrection.make`. Tropical adds 600 K warmth, which is scaled down when the colour cast is weak, and more saturation, which is scaled down in neon water. Deep Dive adds +0.10 shadow lift, 0.85× water chroma and more clarity. The vibrance difference is almost zero on the test scenes: Natural's final vibrance is 0.005. The Tropical and Deep Dive tests in `PresetTests` pass.
- **Natural pin regenerated (29 Sep 2026).** `edcc663` added `referenceGains` and `referenceStrength` (bright-scene white reference) without updating the pin. No existing value moved; the step is active on 3 of the 18 fixtures. Jake chose to keep `edcc663`, so the pin now includes it.

## Offer code redemption (29 Sep 2026)

Get Pro → Redeem Code opens Apple's sheet. Checked on the simulator: the button shows in Korean for a non-Pro user. The sheet itself was not opened.

Still open, by hand with a sandbox offer code (PurchaseTests are not run):
- Redeem in the app: Pro unlocks and "UnderBlue Pro is unlocked." shows.
- Redeem with the redemption URL while UnderBlue is closed: Pro is on at the next launch.
- An invalid or used code: Apple's sheet shows the error and Pro stays locked.

## Changes waiting for the final round

| Commit | Change |
|---|---|
| `a439df0` | Highlight shoulder: highlights roll off instead of clipping |
| `13ffbee` | Custom user preset: five saved sliders for photo, batch and video |
| `e02c19e` | Tropical and Deep Dive tuned to match their names |
| `7651372` | Custom Saturation and Temperature made visible (wider ranges) |
| `8b9f278` | Tropical and Deep Dive made clearly distinct from Natural Dive; accepted on iPhone in `7b1a015` |

## Long-video notice (28 Sep 2026)

A video of 45 s or more shows "Analysis and correction can take longer for longer videos." above "Analyzing…" (`EditorModel.longVideoSeconds`).

Checked on the iPhone 17 simulator (iOS 27.0), in Korean, with a 50 s clip: the notice showed above "분석 중…".

Still open:
- A video shorter than 45 s shows no notice.
- The export progress box shows the same notice for a video of 45 s or more (added after the first check; build only).
- The same check on the iPhone, and in landscape.

## Share sheet opens UnderBlue (28 Sep 2026)

29 Sep 2026: Jake checked the share sheet on the iPhone.

The extension opens `underblue://share` after the copy, through the `UIApplication` object on its responder chain.

Checked on the iPhone 17 (iOS 27.0) with a temporary UI test: Photos → Share → UnderBlue.

| Shared item | UnderBlue came to the front | Editor |
|---|---|---|
| 1 video (14 s) | Yes | Opened, showed "Analyzing…" |
| 1 photo | Yes | Opened with the preview and Natural Dive selected |

Still open:
- Several photos: UnderBlue opens on the batch screen.
- A partial share: the sheet stays with the note and the Open UnderBlue button, and the button opens UnderBlue.
- Share while the editor is open: UnderBlue comes to the front on that editor, and the share opens after going back.
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

- **Signing: done on 28 Sep 2026.** Automatic signing registered `com.underblue.app.share` and the App Group `group.com.underblue.app`. The device build embeds a development profile with the App Group in the app and in the extension. The App Store profile is created again at the next archive.
- **Share sheet in Photos.** UnderBlue appears in the app row for 1 photo, 10 photos and 1 video. It does not appear for 11 photos or 2 videos. After "Added to UnderBlue", UnderBlue opens by itself, and the share opens in the editor or the batch screen.
- **Share edge cases.**
  - A Live Photo opens as the still photo.
  - Share while the editor is open: nothing replaces it; the share opens after going back.
  - Free user shares 5 photos: only the first opens, with the Pro notice.
  - Share a RAW (DNG) from Photos and a file from the Files app.
- **Import from Files.** HEIC, JPEG, iPhone ProRAW DNG, one other camera RAW (ARW/CR3/NEF), MOV and MP4. Include one iCloud Drive file that is not downloaded yet.
- **File names in Photos.** Check the name in the photo's info panel after saving:
  - From Files and the share sheet: `<original>_UnderBlue_<look>.jpg` (or `.heic`).
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

## Colour tuning and m5 reference adaptation (29 Sep 2026)

The colour rules first changed to move toward the AquaColorFix look
([benchmark](AquaColorFixBenchmark.md)), then gained a bright-scene reference adaptation for m5.
Static results and known regressions are in [M5ColorEvaluation](M5ColorEvaluation.md) and
[AdditionalReferenceReview](AdditionalReferenceReview.md). Run the remaining checks before release:

- **Holdout.** Run after the final 29 Sep static candidate: 20.3411 combined and 20.3539 uniform,
  against 20.4373 and 20.4364 from the pre-change source snapshot. The mean improved, but
  `144_img_.png` regressed by 1.53 on uniform; this is not an unconditional pass.
- **Presets on the new colour.** Done on 29 Sep: Jake checked and accepted the tuned Natural,
  Tropical and Deep Dive presets on the iPhone (`8b9f278`, recorded by `7b1a015`). The Natural Dive
  pin was regenerated for the reference-adaptation values. Repeat this check only if colour or
  preset values change again.
- **Market pairs by eye.** m1 and m4 lost about 1.5 ΔE against their targets and m2 lost 3.9 (its mid-tones are darker than the target). The AquaColorFix gate gained 8.2. Decide by eye which look the product wants on m2 (a dark, murky turtle scene).
- **Custom sliders.** The tone values under the sliders changed (shadow lift, highlight compression). Re-measure the caps in `CustomAdjustments.Caps`.
- **Real video.** The subject light removal and the trusted blue reference were not seen on video. Watch a bright fish or diver against blue water for a warm flicker.
- **Fine detail layer on the iPhone (28 Sep 2026, `07c004d`).** The harness judges a 960 px render; a full-size export has a 7.6 px blur radius. Check on a photo export at 100%: the mola or a fish body is crisper, its outline has no halo, open water shows no new grain. Check Custom Clarity at +100 on a dark, noisy photo (the noise floor does not scale with the slider). Check one real clip for shimmer in textured areas; the fix if it shows is a higher floor per clip. Export time on a 4032 px photo is unmeasured.
- **Depth model on Core AI.** iOS 27 ships `CoreAI.framework` (`AIModel`, `InferenceFunction`, `.aimodel`), and `apple/coreai-models` has a Depth Anything **v3 small** export (float32). Our depth model is Depth Anything v2 small fp16 on Core ML. Nothing in the app's colour path uses a model; only `DepthEstimator` would change. Decide later whether to add an iOS 27 path; it needs a new depth-quality and holdout measurement, because the model is different.
- **Video: values that follow the light.** Today a clip gets one set of values from 10 samples. So a clip whose light changes is right in some parts and wrong in others (the product owner, 28 Sep 2026). The analysis is a 48x48 statistic and needs no model. It can run on every frame or every few frames and be smoothed over time before `make()`. Only the depth model is costly, and the record says per-pixel depth did not help video. Design this as its own step. It changes `VideoRestorationAnalysis`, not the colour rules.

## Local veil and shadow toe (30 Sep 2026)

Three changes, all on photo and video:

- **Local veil.** The restoration scales the veil by the broad light around each pixel. The broad light is a blur of 5% of the short side. The scale is its share of the scene's water level, within 0.33x to 3x. One veil per scene had left a grey-pink band in sunlit water and a hard shadow on a fish school.
- **Veil colour follows the light.** The local veil also takes the broad light's colour, at the same luminance. The scene veil was bluer than whitish surface light. Taking it away left red and blue, so surface light turned pink or violet.
- **Shadow toe.** Contrast and brightness now run in `UnderBlueBlackOffset`. Values below twice the black offset get a quadratic toe instead of a clip to black.

Measured on the Mac (harness, videosim). `292facd` has the local veil and the shadow toe; the last column adds the veil colour:

| Check | `9ee3bb6` | `292facd` | Veil colour |
|---|---|---|---|
| AquaColorFix gate, photo / video path | 12.27 / 12.82 | 11.23 / 11.01 | 12.87 / 12.96 |
| m5 full / panel dE | 17.25 / 20.68 | 14.70 / 19.65 | 13.34 / 19.98 |
| Challenge video band (OKLab C < 0.05) at 32 / 36 / 38 s | 15.1 / 28.8 / 31.4% | 1.9 / 4.2 / 18.9% | 0.4 / 3.1 / 22.7% |
| video2 pink or violet share at 0 / 5 / 20 / 32 s | 34.9 / 30.2 / 6.9 / 34.0% | 12.7 / 4.3 / 7.0 / 10.6% | 1.1 / 0.1 / 0.0 / 0.1% |
| video2 at 5 s, near-black share on the dark manta (source 11.2%) | 52.0% | 19.0% | 19.0% |

The gate got worse with the veil colour, mostly on pair 2 (12.56 to 17.06). The napoleon wrasse is cooler. m5 improved, and m5 wins when the two disagree (Jake, 30 Sep 2026).

Known gaps:

- The challenge video at 38 s keeps a beige ring around a dark blue centre, like a vignette. The frame is almost all veil. After veil removal about 30% of the light is left. That is right at the `keepHueWhereDark` threshold. A broad-light version of that rule was tried and did not remove the ring. The Help guide now says that very dark or very bright scenes may not look as expected.
- Gate pair 1 got darker (7.40 to 9.19).
- The steady part of the challenge video (8 s) looks flatter by eye, and its corners look pink-beige. Neither is measured.

Run before release:

- **iPhone photo export.** Check a full-size export of a reef and a bright blue-water photo. Look for halos where a subject meets open water. The broad blur is 5% of the short side.
- **iPhone video export.** Export `challenge_video/original.MP4` and `challenge_video/video2`. Check the band at 32–38 s, the pink surface light, and the manta at 5 s. Watch the fish school edge for a moving halo or flicker: the broad blur is computed per frame.
- **Export time.** The restoration now has one more blur per frame. Video export time is unmeasured.
- **Holdout and presets.** Re-run the UIEB holdout. Check Tropical and Deep Dive by eye, because the restoration and the tone step changed.
- **Custom Brightness down.** Check that dark areas keep their grades at the slider's minimum.
- **Video analysis on the iPhone (1 Oct 2026).** The whale shark clip in `challenge_video/video3` failed its whole scene analysis twice (diagnostic code 6). Then it got the neutral standard correction, which made it bluer. One unreadable keyframe stopped the analysis; an audio track longer than the video by more than 0.13 s causes that. Keyframes now stay inside the video track, and an unreadable keyframe is skipped. The file in `video3` is an UnderBlue export, not the original. Open the original from Photos again: no fallback notice, and Natural Dive removes the blue cast.
- **Video flicker at short scenes (1 Oct 2026).** `video2` pumped in brightness at 14 to 18 s. The camera turned toward the surface and back, and scenes of one or two keyframes switched the values against the light. A short scene between two held scenes (3 or more keyframes) is now skipped; its neighbours fade across the whole gap. On the Mac (videosim, 0.1 s steps): frames moving against the source 15 to 8, largest frame-to-frame change 0.0346 to 0.0157 (source 0.0147). The challenge clip is unchanged. Export `video2` on the iPhone and watch 13 to 19 s.
- **Bright exception off in the kernels (1 Oct 2026).** Sunlit water 1.3 to 1.8 times brighter than the water took the white reference as a pale subject. It turned grey, with a lavender band at the blue water (`doubleJ/IMG_7400` light rays). The kernels no longer apply that exception; the white reference strength still uses it. On the Mac: m5 13.34 to 13.17, AquaColorFix gate 12.87 to 13.01. IMG_7400 against AquaColorFix went 14.14 to 15.45: the light stays teal, which Jake preferred by eye. Check sunlit water and pale bellies (a manta, a sunfish) on the iPhone.
- **Video vignette, two platform causes (1 Oct 2026).** The challenge clip showed a dark ring and lavender bottom corners. The same Core Image code failed differently on each platform:
  - Mac: CIHighlightShadowAdjust changed the frame's edge band on the restored path. A clamped input fixes it (videosim corner minus mid-ring lightness at 4 / 12 / 24 s: 0.081 / 0.107 / 0.127 to 0.003 / 0.024 / 0.077; source 0.004 / 0.028 / 0.049).
  - iOS (simulator and iPhone 17): a smoothed copy of the restored image as the colour kernel's reference input broke the edge rows and darkened the output about 7%, even at a reference strength of 0.0009. The kernel now reads the same image. `VideoRestorationTests.testRestoredVideoFrameKeepsItsEdges` failed before (0.961) and passes on both.
  - Cost on the Mac harness: m5 13.17 to 13.30, colour noise on m5 sand 0.40 to 0.77 and coral 2.14 to 2.71. On iOS the smoothing never worked as intended.
  - Check on the iPhone: export the challenge clip and a bright reef photo with sand (reference adaptation), and look for corner rings and noise.

## HDR photo export (28 Sep 2026)

29 Sep 2026: the real HDR photo and video checks are not done. There is no HDR source yet.

Checked:
- iPhone 17, PhotoHDRTests (3 of 3 pass). A synthetic HDR photo (headroom 4) exported as a JPEG with an ISO gain map. The output headroom was 4.0 and the highlights reached 4.5. The SDR image in the file matched the normal SDR export (average and maximum).
- Simulator: 22 affected unit tests pass. The end-to-end HDR test skips there, because the simulator opens every gain-map photo with headroom 1.

Still open, on the iPhone:
- A real iPhone HDR photo: Export shows SDR/HDR with HDR selected for Pro. The saved photo looks brighter in Photos than an SDR save of the same edit. Colours match between the two saves.
- Memory and time for a 48 MP HDR photo. HDR export renders the full image twice (SDR and HDR).
- The batch screen with a mix of HDR and SDR photos.
- An iPhone without an HDR display: it is unknown whether photos read with headroom above 1 there.
- Live Photos: by decision (28 Sep 2026), a Live Photo imports and exports as its still photo. The motion is not kept, because underwater Live Photos are rare. Check that a Live Photo imports as its still photo from the picker, the share sheet and Files.

## Renamed to UnderBlue (28 Sep 2026)

The app was never uploaded, so the name and every ID changed:
- The first working name: it is a live US trademark for aquatic exercise gear (reg 1550289, class 28).
- MarineLens: a live iPhone app already uses that exact name (NEXASPHERE INC., id 6772336245).
- UnderBlue: the iTunes Search API returned 0 results for "underblue" in the US, KR, JP and GB stores.

New IDs: bundle `com.underblue.app` / `com.underblue.app.share`, App Group `group.com.underblue.app`, product `com.underblue.pro`, URL scheme `underblue://`. Folders, targets, module and kernels use UnderBlue. GitHub: `jakeleekr13-otter/underblue` and `underblue-support` (Pages: https://jakeleekr13-otter.github.io/underblue-support/).

Checked:
- The built app and share extension have those bundle IDs, display name UnderBlue, and URL scheme `underblue`.
- 86 unit tests passed (ExportNaming, Diagnostics, PhotoFormat, Preset, Restoration, Trial). 1 device-only test was skipped.
- `AppStoreAssets/Screenshots/en-US/final-v2/` was regenerated. The label reads UNDERBLUE. The source captures show no app name.

Still open:
- Trademark search for UNDERBLUE: USPTO, KIPRIS, EUIPO. These could not be searched from here.
- Create the app record in App Store Connect early, so the name is held.
- On the iPhone, the new bundle ID installs as a new app. Check that the home screen and share sheet show UnderBlue. Delete the app installed under the old bundle ID.
- The new App Group and app IDs get registered on the first device build with automatic signing.
- The screenshot source captures still show the old colour output. Capture them again after colour tuning ends.
- `scripts/generate_localizations.py` is stale. Its output differs from the catalog by about 6,000 lines. Do not run it.

## Final round checklist

1. **Colour scorecard.** The 29 Sep candidate was run as `m5-final2-dev-20260929`; rerun if any
   colour source changes. Check every guard in [the harness README](../scripts/color-eval/README.md#guards-used-for-tuning),
   including individual regressions that an improved mean can hide.
2. **Holdout, once per final candidate.** The 29 Sep final static candidate was checked once:
   20.3411 combined and 20.3539 uniform. If the implementation changes again, treat that as a new
   candidate and run a fresh holdout only after tuning is frozen.
3. **Presets.** The tuning round checked each preset at intensity 0.8, on photos only:
   - Tropical on shallow, bright scenes: r03, r08, r10, m5
   - Deep Dive on deep, dark-blue scenes: r02, r09, r11, r12, r13
   - Still to check:
     - UIEB dev and holdout for Tropical and Deep Dive
     - intensity values other than 0.8
     - by eye: done on 29 Sep; the three presets were distinct enough to match their names and accepted on iPhone
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
6. **Full unit tests.** Run `xcodebuild test -scheme UnderBlue -only-testing:UnderBlueTests -skip-testing:UnderBlueTests/PurchaseTests` on a simulator.
7. **UI tests.** Run `UnderBlueUITests`. See the known failures below.
8. **Custom UI by hand.**
   - Custom sliders on a video. The simulator has no videos, so the UI test skips it.
   - Custom on the batch screen. The UI test needs Pro.
   - VoiceOver on a device.
9. **App Store text.** Update the preset descriptions after the preset check.

## Known issues to keep in mind

- **PurchaseTests are not run** (decision, 29 Sep 2026). Purchases are checked by hand with a sandbox account instead. See `QA.md`.
  - Why they hang: storekitd rejects the test session with "com.underblue.app is not installed for development" (`SKInternalErrorDomain Code=3`).
  - StoreKit then uses the real sandbox. `purchase()` waits for a sandbox sign-in that never comes, and the test has no time limit.
  - Seen on 25 Sep and 29 Sep 2026. Why storekitd rejects the app is unknown.
- **LongVideoTests can fail under load.** In one full run, the memory growth was 424 MiB against a 220 MiB limit. Another agent was running at the same time. Run alone twice, it passed with 134 MiB and 154 MiB.
- **UI tests that already failed at `6a850b4` on this simulator:**
  - `UnderBlueUITests.testPhotoImportPresetsCompareExportSaveAndTrialGate`, lines 24–29
  - `UnderBlueUITests.testVideoImportAndLandscapeEditor`: the picker shows "No Videos"
  - `AppStoreScreenshotTests.testPhotoBeforeAndAfter`, line 35
- **`xcodebuild test` can hang after the last test.** On 28 Sep 2026 the results were complete at 07:46, but the process was still running 10 minutes later. Read the log, then stop the process.
- **A build can rewrite `Localizable.xcstrings`.** It adds a space before every colon and auto-extracts keys. If `git diff --stat` shows thousands of changed lines, restore the file.

## Done on 25 Sep 2026

- The two device-only tests passed on an iPhone 17 (iOS 27.0):
  - `testBundledDepthModelProducesCompactFiniteDepth`: one depth inference took 32.6 ms
  - `testFiveFrameAnalyzerOnPhysicalDevice`: 14.1 s in total
- Unit tests at `e02c19e`: 127 run, 2 skipped (device only), 0 failed. An earlier full run failed only the LongVideoTests memory test, under load (see above).

## Ideas, not planned

- **Mac.** Planned (Jake, 1 Oct 2026): a Mac version sold at a higher price, built around an enhanced batch job for many photos and videos at once. Core Image renders some filters differently on the Mac and iOS (see the video vignette entry above), so the Mac app needs its own gate and m5 run. Decide then whether the reference smoothing returns on the Mac only. The project is iPhone only today (`TARGETED_DEVICE_FAMILY = 1`). Mac support and Mac Catalyst are both off. The Processing code already runs on a Mac: the harness compiles it into a Mac tool. The smallest step is to run the iPhone app on Apple silicon Macs. It still needs a check of the photo picker, saving, StoreKit and video export on a Mac.
