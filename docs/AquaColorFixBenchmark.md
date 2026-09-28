# AquaColorFix benchmark

This benchmark compares five full-resolution triplets in `DeveloperMedia/aquacolorfix`:

- `On`: source
- `Hn`: MarineLens output
- `An`: AquaColorFix output

AquaColorFix is a product-look target, not ground truth. Its watermark region is excluded from every
image with the same mask. Measurements run on aligned 960-pixel images. Water, bright-neutral and
subject masks are derived once from each source, then reused for both outputs.

Run it with:

```sh
python3 scripts/color-eval/aquacolorfix_benchmark.py
```

The default output is `$TMPDIR/marinelens-aquacolorfix-benchmark` and contains `report.md`,
`benchmark.csv`, `benchmark.json` and `comparison.jpg`.

## Result

| Pair | Mean ΔE H→A | Source→H | Source→A | Mean L* H/A | Neutral C H/A | Water hue H/A | Detail H/A |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 10.25 | 25.30 | 31.09 | 49.2/48.0 | 0.075/0.068 | 250°/240° | 5.76/6.66 |
| 2 | 32.31 | 65.25 | 42.52 | 41.7/36.9 | 0.056/0.049 | 264°/263° | 1.23/2.07 |
| 3 | 9.92 | 19.90 | 19.06 | 50.2/45.8 | 0.058/0.053 | 242°/242° | 5.65/8.10 |
| 4 | 10.56 | 19.61 | 24.43 | 49.3/43.8 | 0.050/0.041 | 242°/239° | 5.39/7.73 |
| 5 | 17.66 | 48.63 | 63.52 | 48.2/44.6 | 0.038/0.021 | 261°/240° | 5.24/7.59 |

Aggregate findings:

- Mean MarineLens-to-AquaColorFix gap is ΔE76 **16.14**.
- Mean source change is almost identical: MarineLens **35.74**, AquaColorFix **36.12**. AquaColorFix
  is not simply a stronger correction.
- AquaColorFix is **3.9 L*** darker on average.
- Its global L* contrast is 13.2% lower and block-local L* contrast is 9.4% lower. These samples do
  not support CLAHE-like contrast expansion as the main difference.
- Its bright-neutral chroma is **16.7% lower**. White and grey subjects are more neutral.
- Its water hue averages about **245°**, versus MarineLens's **254°**. MarineLens more often leaves
  water near indigo; AquaColorFix usually moves it toward azure/cyan.
- Its fine-detail/noise energy is **38.1% higher**. The images visibly contain stronger sharpening
  and more grain. This measurement combines genuine detail, halos and noise, so matching it fully
  is not automatically desirable.

Pair 4 also has an independent target, `DeveloperMedia/market/ref/m6.png`. MarineLens is ΔE76
**24.03** from it and AquaColorFix is **19.08** from it. This one independent reference supports
the product owner's visual preference, although it is not enough to establish ground truth generally.

## What AquaColorFix is doing differently

The channel-gain measurements do not show a missing global red boost in MarineLens. In pairs 1, 4 and
5, MarineLens raises red more than AquaColorFix. AquaColorFix still produces the more convincing neutral
subject because it suppresses surviving green and blue differently and separates water from subject
colour more effectively.

The largest failure is pair 2. MarineLens changes the source by ΔE 65.25, much more than AquaColorFix's
42.52. It turns the fish pale lavender and lifts the blue background. AquaColorFix keeps the deep blue
water while moving the fish toward warm grey. Increasing MarineLens's overall strength would make this
case worse.

Pair 4 exposes the same problem on a white manta: MarineLens leaves a mint cast while AquaColorFix
neutralises the body and warms the reef. Pair 5 shows MarineLens leaving the reef lavender while
AquaColorFix separates a warm reef from blue water.

A cross-validated quadratic RGB mapping explains both apps within roughly 3–9 8-bit code values.
AquaColorFix is actually more globally explainable in four of five pairs:

| Pair | MarineLens RMSE | AquaColorFix RMSE |
|---:|---:|---:|
| 1 | 6.43 | 4.68 |
| 2 | 6.89 | 2.62 |
| 3 | 6.94 | 7.53 |
| 4 | 8.73 | 6.22 |
| 5 | 5.76 | 4.56 |

These five samples provide no evidence that per-pixel depth correction or CLAHE is the main source of
AquaColorFix's advantage. Most of the gap can plausibly come from a better scene-level colour mapping,
water/subject gating, tone curve and sharpening. Depth may still help, but it should not be the first
change made from this benchmark.

## Implementation priorities from the benchmark

1. **Fix bright-neutral and subject colour first.** Replace the single averaged white reference with
   robust OKLab candidate clustering or a median candidate. Protect true yellow fish and warm coral.
2. **Move water toward the target without whitening it.** Reduce the remaining indigo bias, especially
   in pairs 1 and 5, while preserving the saturated blue background in pair 2.
3. **Use tonal masks for subject correction.** Apply the neutral/warm correction mostly to lit midtones
   and highlights. Do not add another unconditional red boost; MarineLens already has enough red gain.
4. **Tune tone separately from colour.** AquaColorFix is darker and has less broad contrast. Lower the
   median/highlight level before deciding whether haze removal needs to become stronger.
5. **Add restrained detail enhancement last.** Raise edge detail with a noise/flat-water guard. Do not
   copy AquaColorFix's full grain increase.
6. **Re-evaluate depth only after the colour mapping ablation.** Add depth-conditioned finishing only if
   a scene-level mapping cannot close the remaining spatial residual.

The first development gate should use pairs 2, 4 and 5. A candidate should materially lower H→A ΔE
on those three, reduce bright-neutral chroma, and keep all existing neutral-ramp, violet/indigo and
holdout guards passing. Results on five images are enough to choose the next experiment, but not enough
to tune final production constants; the set should grow before release tuning.

## Development gate

`scripts/color-eval/aquacolorfix_eval.sh <name>` renders O1–O5 with the working-tree Processing sources
at 960 px (Natural Dive, intensity 0.8) and scores the photo path (`combined`) and the video path
(`uniform`) against A1–A5. It prints one line per path. The harness stands in for the app: its `combined`
render is within ΔE76 3.3 to 4.9 of the iPhone exports H1–H5 on every pair, while the source images are
20 to 65 away.

## Result after the tuning of 28 Sep 2026

Harness numbers, mean ΔE76 to AquaColorFix. "Before" is the committed code (`c411a2e`) rendered by the
same harness, so both columns share one render path.

| Pair | Before | After (photo path) | After (video path) |
|---:|---:|---:|---:|
| 1 | 10.71 | 8.74 | 9.06 |
| 2 | 30.47 | 12.88 | 11.87 |
| 3 | 11.42 | 9.69 | 11.11 |
| 4 | 12.96 | 10.69 | 12.71 |
| 5 | 18.68 | 13.92 | 14.30 |
| Mean | 16.85 | 11.18 | 11.81 |
| Gate (2, 4, 5) | 20.70 | 12.50 | 12.96 |

| Measure | Before | After | AquaColorFix |
|---|---:|---:|---:|
| Bright-neutral chroma, mean | 0.065 | 0.043 | 0.046 |
| Mean L* | 47.7 | 45.6 | 43.8 |
| Water hue, pairs 1 to 5 | 246 / 260 / 236 / 236 / 257 | 238 / 262 / 239 / 235 / 247 | 240 / 263 / 242 / 239 / 240 |

What changed, in the order of the priorities above (details in [Colour algorithm](ColorAlgorithm.md)):

1. Bright neutrals and subjects: pixels that are not water-like lose part of the water's colour
   (`subjectTone`), never past grey. The white reference trusts a strongly blue candidate and only
   removes a cool cast. Pair 2's fish went from lavender to warm grey; pair 5's reef from lavender to
   brown; pair 4's manta lost most of its mint.
2. Water: the hue goal is azure (240) reached in full, with wider solver bounds. Deep, dark water keeps
   more of its chroma, so pair 2's background stays deep blue.
3. Tonal masks: the light removal acts per pixel by the water-like weight, so the water keeps its tone.
   No new red boost was added.
4. Tone: less shadow lift, highlight compression in hazy scenes, and a small darkening under the
   highlight rule. The median lift is now close to AquaColorFix's on pairs 1, 2 and 3. Pairs 4 and 5
   stay 4 to 6 L* brighter in the mid-tones and 5 to 7 L* brighter in the highlights.

Priority 5 (restrained detail enhancement) was added later the same day. It is a fine detail layer on subjects, gated by the white-reference weight, with a noise floor and an edge band. Harness numbers, fine-detail energy (mean absolute Laplacian of L*):

| Pair | Before | After | AquaColorFix | Water region before / after / AquaColorFix |
|---:|---:|---:|---:|---|
| 1 | 7.37 | 9.40 | 6.66 | 6.49 / 8.46 / 5.44 |
| 2 | 1.12 | 1.51 | 2.07 | 0.21 / 0.22 / 0.17 |
| 3 | 5.07 | 6.79 | 8.10 | 4.26 / 5.59 / 6.52 |
| 4 | 6.40 | 8.63 | 7.73 | 2.75 / 2.79 / 3.50 |
| 5 | 6.15 | 7.53 | 7.59 | 4.44 / 5.49 / 5.17 |

The gate moved from 12.50 to 12.54 (photo path) and 12.96 to 13.02 (video path). The "water region" is the least red third of the source. On pairs 1, 3 and 5 it holds particles and small fish, which the layer sharpens as subjects. At 100% the open water looks the same as before. Pairs 1 and 4 now carry more energy than AquaColorFix; one strength serves every scene.

Not done from this benchmark: any depth change (priority 6).

Still open on these five pairs: pair 2's fish keeps a faint green-yellow tint on its face and fins
(OKLab chroma about 0.02) and is about 10 L* brighter than AquaColorFix's; the darker half of pair 4's
manta keeps some mint; pair 5's fish school stays pale cyan where AquaColorFix has it warm.

The older guards after this change are in [Colour algorithm](ColorAlgorithm.md#current-scorecard).
