# Video V2 implementation

Video V2 is a SeaThru-inspired depth-aware restoration path, not SeaThru or SeaThru-NeRF.

## Architecture

- `DeviceCapabilityProfiler` measures `.all` for the provisional first-clip policy, then benchmarks `.cpuAndNeuralEngine` at utility priority after the preview analysis is ready. It caches the faster policy for the current OS major version and model/profile version, so the second model load never blocks the first visible preview.
- `VideoSourceProfile` records duration, display size, frame rate, codec, bit depth, dynamic range, approximate bitrate and a pixel-throughput workload class without decoding the clip.
- `ProcessingPolicyBuilder` combines device capability, source workload, runtime thermal state and preview/export purpose. Analysis uses its depth-map size. The export fields for depth cadence and environment checks still exist, but nothing reads them since per-frame inference was removed.
- `VideoRestorationAnalyzer` builds one filter for the whole clip:
  1. It skips the first and last 10% of the clip. The 10% is an assumption; it is not a confirmed product value.
  2. It takes 10 evenly spaced frames between 10% and 90%.
  3. For each frame it measures the water analysis. It also runs one depth inference and fits a restoration plan.
  4. `WaterAnalysis.sceneInliers` drops whole samples that stand out, for example a surface frame. At least half of the samples always stay.
  5. `WaterAnalysis.sceneMean` and `RestorationPlan.sceneAverage` average the kept samples. Both use the same kept-sample list.
  6. `sceneLevel()` replaces the depth map with one constant value in a 2×2 map.
- Every frame of preview and export gets that same plan. `VideoRestorationAnalysis.exportPlan(at:preservesHDR:)` only raises the output limit for HDR.
- Export runs no depth inference. The only depth inferences happen during analysis, one per sample.
- If no kept sample has a usable plan, the clip uses only the HydroTone correction (`legacyAnalysis`).
- `RestorationEngine.combined` performs the inverse image-formation operation in a stitchable Core Image Metal kernel. Per-channel recoverability limits the physical correction before the HydroTone finishing and intensity blend. Photo and video share this entry point.

Optical flow is disabled. With one plan for the whole clip, it has no role.

## Preview behavior

The current product has a filtered `VideoPlayer`, not a separate Before/To Be thumbnail widget. A representative 50% frame is cached for DEBUG comparison. The player applies the one scene plan to every frame, so preview and export match. Preset changes build and assign a fresh video composition. A generation token stops an older asynchronous refresh from replacing the newest selection.

Before physical analysis is available, the existing HydroTone filter composition remains usable. When analysis completes, one completed composition replaces it. Preset changes do not rerun depth inference.

## Confidence formula

The scalar physical-restoration gate is the minimum of overall fit, depth, water-fit and temporal confidence. Effective per-channel weights are:

`scalar gate × channel recoverability RGB`

This prevents a strong green/blue signal or powerful device from hiding an unrecoverable red channel. If any physical stage fails, video processing continues through the existing HydroTone path.
