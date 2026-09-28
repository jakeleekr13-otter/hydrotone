# Colour algorithm

This page describes how HydroTone corrects underwater colour. It is for developers who change the colour pipeline.

## Purpose and product rules

- Analysis measures the scene. `ColorCorrection.make(analysis:preset:plan:)` turns the measurements into named values. It is the one pure mapping. `FilterEngine` only applies values.
- Photo, batch and video share one entry point: `RestorationEngine.combined`.
- We use our own simple, explainable logic. General optics is fine. We do not copy research code or tables.
- Target look: clear cyan-to-blue water, warm natural subjects, more contrast and clarity, slightly brighter. Not grey, not violet or indigo, not neon.
- Order: particle and noise removal come before colour correction. Sharpening and deblur come after them. Neither is done yet.

## Pipeline overview

1. `FilterEngine.analyze` measures a `WaterAnalysis`.
2. A depth map and `WaterModelEstimator.estimate` give a `RestorationPlan`.
3. `ColorCorrection.make` runs twice. Without a plan it gives the values for the source image. With a plan it gives the values for the restored image.
4. `RestorationEngine.combined` builds two results:
   - `current`: the finishing stage (`FilterEngine.finishing`) on the source image, blended by intensity.
   - `depthAware` (the restored path): the restoration kernel, then the finishing stage, blended by intensity.
   - The finishing stage ends with the [highlight shoulder](#highlight-shoulder) on both paths.
5. The output blends `current` into `depthAware` by `physicalWeight`, which is the plan confidence. A low-confidence fit gives almost exactly `current`.

If there is no plan, or the restoration render fails, the output is `FilterEngine.apply` alone (`PhotoProcessor.processed`). Fallback codes are in [Diagnostics](Diagnostics.md#restoration-fallback-codes).

- **Photo:** one image, one analysis, a per-pixel depth map.
- **Video:** 10 evenly spaced sample frames. It drops outlier samples and averages the rest. Every frame gets the same values and one constant depth. See [Video V2](VideoV2.md) for the mechanics.

## Analysis values

`FilterEngine.analyze` reads a 48x48 thumbnail, tone-mapped to SDR. It skips pixels with luminance at or below 0.015 or at or above 0.85.

| Field | Meaning | Drives |
|---|---|---|
| `redLoss` | 1 - red / mean(green, blue) | Red boost in `castGains`, `redRebuild`; red attenuation prior, red recoverability and red gain limit in `WaterModelEstimator` |
| `cyanDominance` | Same value as `redLoss` | Green and blue attenuation priors in `WaterModelEstimator` only |
| `exposure` | (0.22 - median luminance) x 0.6, from 0 to 0.12 | `brightness` |
| `contrast` | Luminance p90 - p10 | `haze` (low contrast = haze), which feeds tone, saturation, shadows and clarity |
| `saturation` | Mean (max - min) / max | `vibrance` (less vibrance for colourful scenes) |
| `meanRed/Green/Blue` | Scene mean colour (linear) | Green-to-blue cast shift, `castStrength`, exposure-neutral gains, restored-path `subjectRed` and `midLift` |
| `midLuminance` | Median luminance | `deep`, `bright`, `tonePivot`, `midLift` goal |
| `waterRed/Green/Blue` | Mean of the least red third of pixels (mostly open water) | `waterType`, water tone target, `neon`, `violetGuard`, `waterRedness`, `waterChroma`, red gate |
| `neutralRed/Green/Blue` | Mean colour of the white-reference candidates (see [White reference](#white-reference)). Zero means none were found. | `neutralGains` |
| `neutralShare` | Share of analysed pixels behind that colour | Evidence for `neutralGains` |
| `highShare` | Share of lit pixels (luminance above 0.015) at luminance 0.35 or above. Clipped pixels count too. | The highlight rule in `brightness`, `shadowLift` and `midLift` |

Derived values: `greenOverBlue`, `waterColor`, `neutralColor` and `castStrength`. `waterColor` falls back to the scene mean. `castStrength` is 0 for a neutral scene mean and 1 for a clear cast.

## ColorCorrection values

All values come from `ColorCorrection.make`. The finishing kernel `HydroToneFinishColor` applies the cast, subject light removal, water tone and red values. It also applies `midLift`, `toneCurve` and `tonePivot`. Core Image filters apply the other tone values and clarity. `waterType` only feeds other values in `make()`. `RestorationEngine.combined` uses `physicalWeight`.

### Cast and water tone

| Value | Meaning |
|---|---|
| `castGains` | Per-channel gains: red boost plus a green-to-blue shift. The shift acts only when green/blue > 0.88, and scales with cast and `waterType`. Mean luminance is kept. |
| `waterType` | 0 = blue water, 1 = green or teal. Continuous. The water colour's own red loss (not the `redLoss` field) adds to green/blue, so teal counts as green. A neutral scene gets 0 (`waterType(_:)`). |
| `waterTone` | Gains that move water-like pixels toward the OKLab target from `waterTarget`. |
| `subjectTone` | Gains for pixels that are not water-like: red 1, green and blue at or below 1. See [Subject light removal](#subject-light-removal). |
| `waterSaturation` | Chroma scale for water-like pixels. Below 1 calms neon water. |
| `waterRedness` | Red / (green + blue) of the water. Redder pixels count as subject and are not toned. |
| `waterChroma` | Normalised chroma of the water. Much greyer pixels (silver fish, sand, a diver) count as subject. |

`waterTarget` moves the hue to azure, OKLab 240 (`waterHueGoal`), in full. The market look puts every clear-water scene near one azure: the AquaColorFix outputs sit at 239 to 242 on four of five pairs. Only the chroma limits and the solver bounds hold a scene back. Before 28 Sep 2026 the hue moved halfway toward 238 inside a 222 to 262 band, which left indigo-leaning water at 246 to 257. Near-grey water and colours that are not water keep their hue. `waterCorrection` solves the gains with a coarse grid, damped Gauss-Newton steps, then a short pattern search (without it the solve stopped about 1.5 degrees short). Gains stay in 0.35 to 2.2; the old floor of 0.45 held the blue gain at its bound on deep blue water.

Deep, dark, hazy water keeps more of its colour: the chroma floor for murky water (`murkyFloor`) is 0.22 divided by the later-step factor, up from 0.14. The market look keeps a deep blue background deep (AquaColorFix pair 2: chroma 0.30 to 0.23; ours was 0.17, now 0.20).

The water-like weight uses a chroma test. The test is off below `waterChroma` 0.55 and fully on above 0.8 (`chromaConfidence`). So in murky water, compression steps do not become grey patches. Strongly coloured water still protects greyer subjects such as silver fish. It is a per-pixel rule in the kernel: no inference, blur pass or frame buffer.

### Subject light removal

Subjects are lit through the same water, so they carry its colour: blue, or green in green water. The red boost alone left a reef violet and a white belly mint (AquaColorFix pairs 2, 4 and 5, 26 Sep 2026). So pixels that are not water-like lose part of the water's colour.

- `subjectTone` = (1, (Lr / Lg)^k, (Lr / Lb)^k). L is the water colour after the cast gains (`waterLit`). k is `subjectLightRemoval` (0.4) times the cast strength. Green stays in 0.6 to 1 and blue in 0.35 to 1. Green never rises. Water with less green than red left no green to give back, and extra green turns a fish lime.
- The kernel applies it by (1 - water-like weight), at the pixel's own luminance.
- Green and blue never fall below the pixel's red. A grey subject carries no cast, so it is not made warm; a silver fish stays silver. Beige sand under blue water lands exactly on grey.
- A grey scene has grey water and gets gains of one.

The white reference below reads the result, so a neutral surface needs less from it.

### Red rebuild and guards

| Value | Meaning |
|---|---|
| `redRebuild` | Red added as a share of green. Larger in blue and teal water, smaller in strongly green water. |
| `redGateLow`, `redGateHigh` | Green/blue range where the rebuild starts. The low edge sits 30% above the toned water's green/blue, so the water gets no red. It stays between 0.2 and 0.8 in blue water. In green water it is at most 0.55. So the gate stays low enough for a teal-lit face or hand. |
| `subjectRed` | Red/green of the toned water. On the restored path, it is halfway to the scene mean. Redder pixels get more rebuilt red. |
| `redCeiling` | Rebuilt red stops at this share of green. Fixed at 1.05; `make()` does not change it. |
| `violetGuard` | Strength, 0 to 1. In blue pixels, gains may not lift red above the larger of green and the pixel's own red. In water-like pixels, red stops at green, weighted by this strength. It is 0 when the "water" colour is not a colour open water can have (`waterPlausibility`). An example is a magenta anemone. |

The rebuild also fades out for strongly green pixels, from green/blue 1.35 to 2.2. So weed does not turn yellow.

### White reference

Sand, rock or a white belly should come out near grey. `ColorCorrection.whiteReference` finds gains that do this.

A candidate pixel for the reference must be:

- outside the least red third, so not open water
- in the brightest 20% of the scene
- at least 1.25 x as bright as the water
- no more colourful than the water: OKLab chroma at most 1.1 x the water's, and at most 0.2

| Value | Meaning |
|---|---|
| `neutralGains` | Gains that move `neutralColor`, as the finishing stage sees it, toward grey. One means no reference. Red may rise up to 3x; green and blue may fall to half and never rise (before the luminance normalisation). Luminance is kept. |
| `waterLit` | The water colour after the cast gains. The kernel uses it to find lit subjects inside water-like pixels. |

The gains act only when all of these hold:

- Evidence: from 1% of the scene, full at 6%.
- What is left on the surface after the normal correction is pale: OKLab chroma under 0.10, none from 0.18. The candidates are the bright, low-chroma surfaces, so a pale remainder of any hue is a cast. A colourful remainder is a real colour, such as a yellow fish, and is kept.
- The gains only remove a cool cast. Before the luminance normalisation red is 1 to 3 and green and blue 0.5 to 1. A warm remainder gets gains of one: it is a real colour, or the restoration's own red. This replaced the old hue window (150 to 235) on 28 Sep 2026; the window also rejected the lavender remainder of a blue-lit fish.
- A strongly blue candidate is trusted. A white belly, a grey fish or sand lit by blue water is as blue as pale water near the surface, and no colour test tells them apart. The open water is safe because the kernel applies the gains by `neutralWeight`. Before 28 Sep 2026 such a candidate was rejected, which left the pair 2 fish and the pair 3 mola without a reference.

On the restored path the candidate is first restored at the depth that 35% of the depth map lies below, because a lit surface is usually nearer than the water. The 35% is a simple rule, not a measured one.

The kernel applies the gains by `FinishingMath.neutralWeight`. Water-like pixels get none, so the water keeps its colour. The exception is a pixel 1.3 to 1.8 x brighter than the water and of another chromaticity, like the manta belly. Brighter water of the water's own colour gets none.

### Tone and brightness

| Value | Meaning |
|---|---|
| `midLift` | Restored path: gives back light lost with the veil, the backscatter haze that the water adds. It never lifts the median luminance above 0.22. The highlight rule lowers that ceiling to 0.132, and on both paths it may take the lift down to -0.12: the scene is exposed for its bright subject. |
| `toneCurve`, `tonePivot` | S-curve on gamma luminance around the scene median. Weaker for bright scenes, capped at 0.3. |
| `brightness` | `exposure` x 0.45 (`CIColorControls`). The highlight rule halves it. |
| `contrast` | Preset contrast plus haze (`CIColorControls`). |
| `saturation` | Preset saturation plus haze. Neon water gets a little less. |
| `shadowLift`, `highlightAmount` | `CIHighlightShadowAdjust`. `shadowLift` is 0.2 plus 0.15 x haze (0.28 plus 0.22 x haze before 28 Sep 2026); it reaches the mid-tones too, and the market look sits 3 to 6 L* lower there. The highlight rule keeps 40% of its haze part. `highlightAmount` is 0.92 minus 0.2 x haze: every lift pushes the highlights up, and the market look keeps them 5 to 10 L* lower. |
| `warmth` | Tropical only: `DivePreset.warmth` (600 K) x min(1, 4 x `castStrength`), so a grey scene gets none. Custom adds the user's Temperature. |
| `vibrance` | Preset vibrance, lower for colourful or neon scenes. |
| `physicalWeight` | Restored path only: the plan confidence. |

**Highlight rule.** A large bright area (a white belly, sunlit sand) already lights the scene. So the scene gets less lift, and its mid-tones may go a little darker (`midLift` down to -0.12). The rule's weight rises from `highShare` 0.02 to 0.07. It fades out in two cases:

- dark scenes (median luminance 0.18 down to 0.10), where a few bright spots do not light the scene
- contrasty scenes (`contrast` 0.35 to 0.5), whose deep shadows need the lift

### Clarity

| Value | Meaning |
|---|---|
| `clarity`, `clarityRadius` | Fine unsharp mask. Stronger in haze. |
| `definition`, `definitionRadius` | Broad unsharp mask for the veil over far water and reef. |

Radii are shares of the short image side, so every size looks the same.

### Highlight shoulder

Every finishing step can push a highlight past white, and none rolls it off. Before this rule, bright sand clipped in one channel and turned flat mint (r14). So the last finishing step is a shoulder: kernel `HydroToneHighlightShoulder`, CPU mirror `FinishingMath.shoulder`.

- The peak is the largest channel in BT.709 / sRGB primaries (`FinishingMath.display`). The smallest output gamut clips first.
- The ceiling is 1, or the source pixel's own peak when that is higher. So HDR highlights keep their headroom. The restored path passes the unrestored source, so restoration cannot raise the ceiling.
- Below the knee (ceiling - 0.15) a pixel is unchanged.
- Above the knee the whole pixel is scaled, so its largest channel rolls off toward the ceiling. The hue stays.
- A pixel bright in every channel (smallest channel 0.65 to 0.9 of the ceiling), or 1.3 to 2 x over the ceiling, moves toward white at the same peak. Without this, the sun got a pink ring.

The pure white of an SDR image ends near 250 of 255 at intensity 0.8, because the shoulder never reaches the ceiling.

## Built-in presets

The UI gives each built-in preset only an intensity slider. Their values are in `DivePreset`.

| Preset | For | What it adds to the automatic result |
|---|---|---|
| Natural Dive | any water | Nothing. It is the automatic result and the base for Custom. |
| Tropical | shallow, bright water | `warmth` 600 K; more saturation and vibrance on subjects |
| Deep Dive | deep, dark-blue water | More red (`restoration` 0.56); `shadowBoost` 0.10; `waterChroma` 0.85 calms neon water |

- Preset terms sit in one block in `make()`. Natural and Custom skip it.
- The extra saturation of a preset is meant for subjects. Water-like pixels give it back (`waterSaturation`), so the water keeps Natural's saturation.
- `waterChroma` scales the water tone's chroma ceiling. The water tone keeps the water's hue, so calmer water does not turn violet.
- Warmth is applied as light: the source is taken as lit at 6500 K + warmth and shown at 6500 K. A green tint of 1 per 100 K keeps the shift yellow, not orange.

## Custom preset

Custom is the user preset (gear tile). It starts from the Natural values and renders at full strength (`FilterSettings.customStrength` = 1), so it has no intensity slider. Five sliders change the automatic result. Each is a position from -1 to 1, shown as -100 to +100. `ColorCorrection.make` takes them as `adjustments`; every other preset ignores them.

| Slider | Value it changes | Change at -1 / +1 |
|---|---|---|
| Brightness | `midLift` down, `shadowLift` up | -0.25 / +0.075 |
| Contrast | `toneCurve` | -0.10 / +0.02 |
| Saturation | `saturation`; the water chroma ceiling ignores it, so the water shows it too | -0.45 / +0.35 x (1 - 0.6 x neon) |
| Clarity | `clarity` and `definition`, as a factor | x0 / x1.75 |
| Temperature | `warmth`; a cool shift gets no tint | -1500 K / +1500 K |

- The up moves of Brightness, Contrast and Saturation share one budget. When their sum is above 1, each is scaled down (`CustomAdjustments.budgeted`).
- The offsets enter before the guards and the white reference that read them. The highlight shoulder still runs last.
- Saturation does not move the water tone, the red gate or `subjectRed`. It acts at the `CIColorControls` step, on the water too: at +1 the water gains at most about a third more chroma.
- The caps are provisional (`CustomAdjustments.Caps`). Brightness, Contrast and Clarity were measured before the white reference and the highlight shoulder landed. Saturation and Temperature were widened on 25 Sep 2026 after an iPhone test, without a render measurement. See [Verification](Verification.md).
- One saved slot in UserDefaults (`customAdjustments.v1`) holds the five positions. The editor, batch and video share it.
- Custom gets no preset terms, so with every slider at 0 it equals Natural at full strength.

## Restoration kernel

The kernel is `HydroToneRestoration` in `RestorationEngine.swift`. `RestorationMath` is its CPU mirror.

**Image formation:** `observed = clear x exp(-betaDirect x z) + backscatterInfinity x (1 - exp(-betaBackscatter x z))`, per channel (`RestorationMath.forward`).

The inverse removes the backscatter, then multiplies by `1 / transmission`. These limits apply. Most are in `RestorationLimits`; `channelRecoverability` is in the plan.

| Limit | Value or rule |
|---|---|
| `transmissionFloor` | 0.28 |
| `maximumGain` | Red 1.32 + 0.45 x red survival, green 1.55, blue 1.45, spread by cast (`WaterModelEstimator`) |
| Highlight protection | From peak 0.72 to 1.0, up to 80% of the source is kept |
| `maximumOutput` | 1.15; 8 for HDR video export (`exportPlan`) |
| `channelRecoverability` | Per-channel share of the correction that is applied |

Two hue rules run last:

- **`keepHueWhereDark`**: restoration can leave little light (channel sum ratio below 0.6). There the source hue is kept, at the restored level. So far water does not turn red-brown or violet.
- **`keepBlueFamily`**: a blue source pixel can turn green because the veil took its blue. If green/blue grew 4 to 8 times, the pixel keeps its source hue. This fixes a pale fish read at far-water depth on the video path.

The estimator spreads attenuation across channels only as far as the measured cast (`spread(_:by:)` with `castStrength`). A neutral scene gets equal attenuation, so greys stay grey. Plan confidence is the minimum of four values: the estimator's overall confidence (at most 0.9), depth, water-fit and temporal confidence (`RestorationPlan.init`).

## CPU mirrors and tests

The kernels run in Metal. The finishing kernels are Metal source in `FinishingKernels.swift` (`FilterEngine.colorSource`); their CPU mirrors are in `FinishingMath.swift`. The restoration kernel and `RestorationMath` are in `RestorationEngine.swift`. The value rules are in `ColorCorrection.swift`: `make()` and the white reference. `ColorMath.swift` holds the colour spaces, the water target and solver, the restoration mirror and the lift curve. The CPU mirrors must give the same result:

| Kernel | CPU mirror | Test that compares them |
|---|---|---|
| `HydroToneFinishColor` | `FinishingMath.color`, `waterLike`, `neutralWeight` | `testFinishingKernelMatchesCPUMirror`, `testFinishingKernelMatchesCPUMirrorWithWhiteReference` |
| `HydroToneRestoration` | `RestorationMath.inverse` | `testRestorationKernelMatchesCPUMirror` |
| `HydroToneHighlightShoulder` | `FinishingMath.shoulder` | `testHighlightShoulderKernelMatchesCPUMirror` |

`ColorCorrection.restoredMean` (in `ColorMath.swift`) also mirrors the restoration kernel on one colour, at the plan's mean depth or at a given depth. It skips highlight protection and the output clamp. It predicts the restored water and scene mean. Change it with the kernel.

Other guards in `HydroToneTests/RestorationTests.swift`:

- `testNeutralScenesStayNeutralOnBothPaths`
- `testDarkFarWaterKeepsItsHue`, `testNearPaleFishAtFarDepthStaysBlueNotLime`, `testBlueFamilyGuardActsOnlyOnBluePixelsThatTurnGreen`
- `testWaterTargetNeverPointsTowardIndigoOrViolet`, `testVioletGuardKeepsBlueWaterFromTurningViolet`
- `testSimilarMurkyWaterColoursDoNotBecomeContrastingPatches`
- `testWaterAnalysisFieldListCoversEveryStoredValue`
- `testCyanCastSurfaceBecomesNearlyNeutral`, `testWhiteReferenceDoesNotNeutraliseTheWater`, `testSceneWithoutNeutralSurfacesIsUnchangedByTheWhiteReference`, `testNeutralRampStaysNeutralWithWhiteReferenceOnBothPaths`
- `testLargeBrightSubjectGetsLessLift`, `testBrightSubjectDarkensAHighlightScene`
- `testSubjectsLoseTheWaterLightButWaterAndGreyScenesDoNot`
- `testSceneInliersKeepFramesWithAndWithoutANeutralSurface`, `testSceneMeanAveragesTheNeutralColourOnlyWhereItWasFound`
- `testHighlightShoulderStopsABrightPixelFromClippingAndKeepsItsHue`, `testHighlightShoulderLeavesPixelsBelowTheShoulderUnchanged`, `testHighlightShoulderTurnsATintedBlownHighlightWhite`, `testHighlightShoulderKeepsHDRHighlightsAboveWhite`, `testNeutralRampStaysNeutralThroughTheShoulderOnBothPaths`

Video averaging treats the white reference apart. `sceneInliers` judges frames by `sceneFields`, the water values only. A white surface or a bright subject comes and goes within one dive, so a frame without one is not odd. `sceneMean` takes the white surface colour only from frames that found one, weighted by `neutralShare`. `neutralShare` itself is the plain mean, so a surface seen in few frames counts for less.

A change to one kernel needs the same change in its mirror.

## How to evaluate a change

Use [scripts/color-eval](../scripts/color-eval/README.md). It compiles the app's own `Processing` sources.

deltaE is the mean CIE76 colour difference to the reference image. Lower is closer. UIEB is a public underwater image set with reference images.

1. Run `scripts/color-eval/aquacolorfix_eval.sh <name>` for the AquaColorFix gate (24 seconds). It prints the five pair ΔE values, the gate mean and the water hues. `HT_EVAL_LOG` shows every value `make()` produced and a probe of the water, neutral and mean colours through the chain.
2. Run `scripts/color-eval/tune_eval.sh <name>`.
3. Check the guards in the harness README. They cover the neutral ramp, dev deltaE, indigo and violet water, green water, the best UIEB images, real photos, market pairs and the AquaColorFix gate.
4. Open the sheets and look at them. The numbers do not show everything.
5. Tune on dev. Check holdout once, at the end.

Water hue uses OKLab. CIELAB hue cannot separate azure (273), pure blue (306) and violet (310). So earlier "violet water" counts, including one commit message, mixed blue with violet. The bands are cyan 180 to 235, blue 235 to 270, indigo 270 to 282, violet 282 and above.

## Current scorecard

Colour code after the AquaColorFix tuning of 28 Sep 2026. "Before" is `c411a2e`, measured by the same harness on the same day.

**AquaColorFix gate** (five private triplets; see [the benchmark](AquaColorFixBenchmark.md)), mean deltaE to the AquaColorFix output:

| Set | Before | Now |
|---|---|---|
| Gate pairs 2, 4, 5 | 20.70 | 12.50 |
| All five pairs, photo path | 16.85 | 11.18 |
| All five pairs, video path | 17.26 | 11.81 |

**Market pairs** (m1-m4: private before/after pairs the product owner chose as the target look; see the harness README), deltaE to the market "after":

| Pair | Original | Before | Now |
|---|---|---|---|
| m1 | 34.0 | 23.1 | 23.1 |
| m2 | 32.7 | 15.3 | 23.7 |
| m3 | 17.5 | 22.0 | 22.4 |
| m4 | 25.0 | 18.3 | 20.1 |
| m5 | 39.0 | 29.1 | 28.0 |
| m6 | 33.9 | 25.2 | 22.9 |

m2 got worse: its mid-tones are now darker than its target (mean L* 31 against 42; before 35.5). The AquaColorFix look keeps a dark scene dark, the m2 target lifts it. This is a product decision; see [Verification](Verification.md). m3 is a mood grade and needs a preset.

**UIEB dev, 40 images:** deltaE 19.20 (before 19.35; 24.16 before the 25 Sep 2026 changes). Video path 18.87 (before 18.95). The original images score 24.51. Indigo or violet water: 0. Green water left: 1 of 6. Beats the original on 82% (before 85%). The best images improved (576: 11.0 to 10.2; 433: 19.5 to 18.2); 108 got worse (21.0 to 23.6, a bright scene we now darken).

**UIEB holdout, 40 images:**

| Version | deltaE |
|---|---|
| Original image | 22.96 |
| `f548c29` | 20.00 |
| `f9b073d` | 20.60 |
| `b8db6df` | 21.01 |
| `6fd84cf` | 20.12 |
| 28 Sep 2026 tuning | unmeasured |

Holdout deltaE rose from 20.00 at `f548c29` to 21.01 at `b8db6df`. The market direction moved away from UIEB's muted references. The white reference brought it back to 20.12. The 28 Sep 2026 tuning was not run on holdout yet.

**Real dive photos, 15, no reference:** none is pushed into indigo or violet. r04's anemone is really magenta (295 in the original, 300 now). Before the 25 Sep 2026 changes, 12 were.

**Neutral grey ramp:** max Lab chroma 0.01 on both paths (before: 0.97 on the video path, the harness's `uniform` stand-in).

**Neutral surfaces**, OKLab chroma (0 = colourless), before and after the 28 Sep 2026 tuning:

| Surface | Original | Photo path, before | Photo path, now | Video path, before | Video path, now | Sea-thru |
|---|---|---|---|---|---|---|
| m5 sand | 0.109 | 0.032 | 0.036 | 0.014 | 0.033 | 0.004 |
| m5 chart, grey row | 0.132 | 0.034 | 0.063 | 0.046 | 0.057 | 0.079 |
| m6 manta belly | 0.111 | 0.026 | 0.029 | 0.033 | 0.046 | 0.063 |

The chroma rose on all three, most on the chart. The residual changed side: before it was cyan (hue 184 to 217), now it is green-yellow (126 to 173), because the light removal takes more blue than green. The harness guard "neutral surfaces do not rise" is not met by this change; the AquaColorFix bright-neutral chroma fell from 0.065 to 0.043.

## Decision record

### Adopted

No separate figure is recorded here for these four. The scorecard shows the combined result.

- Scene water colour and a continuous `waterType`. Teal counts as green through red loss.
- OKLab water tone.
- Red rebuild gated relative to the water, with `redCeiling` and `violetGuard`.
- Scene-key contrast and brightness. `tonePivot`, `toneCurve` and `midLift` read the scene median.

| Decision | Evidence |
|---|---|
| Attenuation spread scaled by cast | Neutral ramp max chroma: 7.7 before, 0.01 now |
| `keepHueWhereDark` and `keepBlueFamily` | A lime fish on the video path: green/blue 1.45 before, 0.86 now |
| Chroma-confidence fade for murky water (`b8db6df`) | Visibly fewer block patches on a compressed murky image |
| Confidence coverage fix (`candidateCoverage` over 8 x 256 samples) | Plan confidence was capped near 0.41 on all 890 UIEB images. The median is now about 0.66. |
| White reference (`neutralGains`) and highlight rule, measured together | Photo path chroma: m5 sand 0.076 to 0.032, m6 belly 0.069 to 0.026. m6 mean L* 54.6 to 48.6. Holdout deltaE 21.01 to 20.12. |
| Video outlier test on water values only | Unit test data: sand in 7 of 10 frames. The old test dropped the 3 frames without sand. It also dropped 1 frame with a bright subject. |
| Subject light removal (`subjectTone`) | AquaColorFix gate 20.70 to 15.41 with the azure goal and the wider bounds; pair 2 (lavender fish) 30.5 to 17.2. Green capped at 1 and the "never below red" clamp: silver fish chroma 0.047 to 0.017, gate 15.40 to 13.60. |
| Trusted blue reference, pale-only gate, cool-only gains | Pair 3 13.2 to 9.6 (the mola is the candidate); grey ramp on the restored path stays 0.01 (a warm restored grey got gains of one). |
| Water hue goal 240 in full, bounds 0.35 to 2.2, solver polish | Water hue on pairs 1 and 5: 246 and 257 to 238 and 247 (target 240). The polish took pair 5 from 16.2 to 13.9. |
| Murky chroma floor 0.14 to 0.22 | Pair 2 water chroma 0.17 to 0.20 (AquaColorFix 0.23). |
| Tone: shadow lift 0.28 + 0.22 haze to 0.2 + 0.15 haze; highlights 0.92 - 0.2 haze; highlight rule down to -0.12 | Gate 13.60 to 12.50; median L* on pairs 1 to 3 within 2 of AquaColorFix (before +3 to +7). Shadows kept the black level: brightness stayed at exposure x 0.45. |

### Rejected

| Idea | Why rejected |
|---|---|
| Jerlov coefficient priors | No measurable gain. They are copied tables. |
| Clear-water veil in the style of UWCNN | deltaE 26.1 against a 24.2 baseline, 40 images |
| Per-pixel depth for video, including optical-flow depth warping | On photos, per-pixel depth was not better than constant depth. Per-pixel minus constant: +0.54 deltaE on dev, +0.25 on holdout, at that time. |
| A finer water-fit beta grid (0.05 to 0.01) | deltaE changed by 0.03 |
| A fixed recipe, for example a +36 magenta tint | It pushes blue water violet. The rules adapt to the measured cast instead. |
| The highlight rule without its dark-scene and contrast fades | UIEB 12324 mean L* fell from 32.2 to 16.3 |
| Warmth from 6500 K to 6500 K + warmth (used until `13ffbee`) | It cooled the image: at +300 K, grey 0.40 became (0.391, 0.401, 0.417). Tropical was cooler than Natural, and its grey ramp chroma was 4.00 (photo) and 4.87 (video), over the limit of 3. |
| Deep Dive calming by scaling `waterSaturation` | It turned 42% of r02's pixels indigo or violet (Natural: 7%) |
| Per-pixel OKLab hue pull of water-like pixels toward 240 (28 Sep 2026) | Gate 15.40 to 20.66. It fights the white reference, whose candidates are water-like, and keeps chroma the gains had removed. |
| Restored-path lift cap 0.5 for the pair 2 fish | Pair 2 17.2 to 19.1: the water went too dark. |
| Brightness (the black level) 0.45 to 0.3, or 0 | Shadows 8 to 10 L* below AquaColorFix on pairs 3 and 5; at 0 the shadows collapsed to L* 3. |
| Murky lift goal 1.2 + 0.9 murky^2 to 1.1 + 0.4 murky^2 | No change on pair 2 (its lift is capped either way); market m2 lost 8 deltaE. |
| Old shadow lift kept with the rest of the tone change | m2 23.7 to 23.1 only; gate 12.50 to 13.02. |

## Comparison with AquaColorFix

AquaColorFix is a competing app whose look the product owner prefers. [The benchmark](AquaColorFixBenchmark.md) compares five triplets and drove the 28 Sep 2026 tuning. Its main findings:

- A global colour mapping explains most of AquaColorFix's output.
- It lowers blue on every subject. Its neutrals are grey or warm, never cyan.
- Its water sits near azure.
- It is about 4 L* darker, with less broad contrast and more sharpening.

The sharpening and any depth change were not taken.

## Comparison with Sea-thru

Sea-thru (Akkaynak and Treibitz, CVPR 2019) uses the same kind of image-formation model as our restoration kernel. Its results are much cleaner, because its inputs are different:

- It uses RAW images, not camera-processed JPEGs.
- It uses measured distance. The distance map comes from several overlapping photos and photogrammetry.
- It re-balances white after removing the veil, so sand and grey surfaces become neutral.

We measured two Sea-thru results (market pairs m5 and m6) with the harness. The "ours" columns show `b8db6df`, then `6fd84cf`:

| Measure | m5 original | m5 ours | m5 Sea-thru | m6 original | m6 ours | m6 Sea-thru |
|---|---|---|---|---|---|---|
| deltaE to the Sea-thru result | 39.0 | 33.1 → 29.1 | (reference) | 33.9 | 29.5 → 25.3 | (reference) |
| Mean L* | 60.1 | 57.9 → 58.3 | 36.4 | 52.9 | 54.6 → 48.6 | 38.7 |
| Subject red/green (`nearRG`) | 0.37 | 0.66 → 0.87 | 1.04 | 0.35 | 0.70 → 0.81 | 0.91 |
| Neutral surface, OKLab chroma | sand 0.109 | 0.076 → 0.032 | 0.004 | belly 0.111 | 0.069 → 0.026 | 0.063 |

What we took, as our own rules:

- A white reference after veil removal (see [White reference](#white-reference)).
- Brightness that respects bright subjects: the highlight rule. The manta belly no longer makes the whole frame brighter.
- Neutral surfaces as a scorecard check (the harness "Neutral surfaces" section).

What we cannot take into a one-photo app:

- Measured distance. It needs several overlapping photos and photogrammetry.
- Distance-dependent attenuation. It only helps with measured distance.
- RAW input would help the photo path. It is possible later; its gain is unmeasured.

## Known limits and next steps

Limits:

- A diver's hand in teal water stays grey-green. Its red is about 10/255, and it is green-family.
- Near subjects on the constant-depth video path go darker and greener. `keepBlueFamily` covers only blue-family pixels.
- On an iPhone 17 (iOS 27.0), both kernel/CPU-mirror tests and the two device-only depth tests pass (4 test suites, 65 tests, 0 failures). One depth inference took 22 ms. Full video export speed on an iPhone is unmeasured.
- Mood grades like m3 are out of scope for automatic correction.
- m5 stays much brighter than Sea-thru (mean L* 58.3 against 36.4). Its original is already bright (60.1).
- On m6 the reef under the manta is olive-green (photo path) or yellow-green (video path). On Sea-thru it is brown.
- Against AquaColorFix: pair 2's fish keeps a faint green-yellow tint (chroma about 0.02) and is about 10 L* brighter. The darker half of pair 4's manta keeps some mint. Pair 5's fish school is pale cyan where AquaColorFix has it warm. Pairs 4 and 5 stay 4 to 6 L* brighter in the mid-tones.
- The neutral-surface residual is now green-yellow instead of cyan, and the chart grey row's chroma rose to 0.063 (see the scorecard).
- Market m2 is darker than its target since the 28 Sep 2026 tuning.
- The white reference on real video is unmeasured. The harness has no video; only unit tests cover the averaging.
- The highlight shoulder on HDR export is unmeasured. It reads its peak in BT.709, so saturated Display P3 colours are held a little lower than P3 needs.
- On the video path r14's sand stays mint-green. The restoration kernel's own limit flattens that colour before finishing.
- The white reference trusts a strongly blue candidate. Pale water near the surface can be that candidate. The open water is protected by `neutralWeight`. A bright patch of water of another colour would be neutralised with the subjects.
- The presets differ only a little. Deep Dive's neon water is only 1 to 1.5% calmer than Natural's.
- Deep Dive turns some of r11's sea fans lavender: 12.1% of pixels have OKLab hue 270 to 330 and chroma 0.03 or more (Natural: 2.7%). The far-water check does not see it.
- Tropical moves some cyan or green water a little greener (m1 water hue 216 to 212, m2 240 to 225). In r10 it gives the sun core a light peach tint.
- The particle filter and temporal denoiser are prototypes in `Prototypes/VideoCleanup`. They are not wired in.

Next steps:

- Add particle removal and temporal denoising before colour correction. Both are prototypes in `Prototypes/VideoCleanup`.
- Add sharpening and deblur after them.
- Measure full video export speed on an iPhone, with the particle filter and denoiser wired in.
