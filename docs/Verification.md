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
6. **Full unit tests.** Run `xcodebuild test -scheme HydroTone -only-testing:HydroToneTests -skip-testing:HydroToneTests/PurchaseTests` on a simulator.
7. **UI tests.** Run `HydroToneUITests`. See the known failures below.
8. **Custom UI by hand.**
   - Custom sliders on a video. The simulator has no videos, so the UI test skips it.
   - Custom on the batch screen. The UI test needs Pro.
   - VoiceOver on a device.
9. **App Store text.** Update the preset descriptions after the preset check.

## Known issues to keep in mind

- **PurchaseTests hang on the simulator.** The StoreKit test session fails with `SKInternalErrorDomain Code=3`. It hung the same way at 14:51 on 25 Sep 2026, before any change on this list. Skip it on the simulator.
- **LongVideoTests can fail under load.** In one full run, the memory growth was 424 MiB against a 220 MiB limit. Another agent was running at the same time. Run alone twice, it passed with 134 MiB and 154 MiB.
- **UI tests that already failed at `6a850b4` on this simulator:**
  - `HydroToneUITests.testPhotoImportPresetsCompareExportSaveAndTrialGate`, lines 24–29
  - `HydroToneUITests.testVideoImportAndLandscapeEditor`: the picker shows "No Videos"
  - `AppStoreScreenshotTests.testPhotoBeforeAndAfter`, line 35
- **A build can rewrite `Localizable.xcstrings`.** It adds a space before every colon and auto-extracts keys. If `git diff --stat` shows thousands of changed lines, restore the file.

## Done on 25 Sep 2026

- The two device-only tests passed on an iPhone 17 (iOS 27.0):
  - `testBundledDepthModelProducesCompactFiniteDepth`: one depth inference took 32.6 ms
  - `testFiveFrameAnalyzerOnPhysicalDevice`: 14.1 s in total
- Unit tests at `e02c19e`: 127 run, 2 skipped (device only), 0 failed. An earlier full run failed only the LongVideoTests memory test, under load (see above).

## Ideas, not planned

- **Mac.** The project is iPhone only (`TARGETED_DEVICE_FAMILY = 1`). Mac support and Mac Catalyst are both off. The Processing code already runs on a Mac: the harness compiles it into a Mac tool. The smallest step is to run the iPhone app on Apple silicon Macs. It still needs a check of the photo picker, saving, StoreKit and video export on a Mac.
