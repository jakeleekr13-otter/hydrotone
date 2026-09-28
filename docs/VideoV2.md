# Video V2 implementation

Video V2 is a SeaThru-inspired depth-aware restoration path, not SeaThru or SeaThru-NeRF.

## Architecture

- `DeviceCapabilityProfiler` measures `.all` for the provisional first-clip policy, then benchmarks `.cpuAndNeuralEngine` at utility priority after the preview analysis is ready. It caches the faster policy for the current OS major version and model/profile version, so the second model load never blocks the first visible preview.
- `VideoSourceProfile` records duration, display size, frame rate, codec, bit depth, dynamic range, approximate bitrate and a pixel-throughput workload class without decoding the clip.
- `ProcessingPolicyBuilder` combines device capability, source workload, runtime thermal state and preview/export purpose. Analysis uses its depth-map size. The export fields for depth cadence and environment checks still exist, but nothing reads them since per-frame inference was removed.
- `VideoRestorationAnalyzer` builds one set of values per scene:
  1. It takes keyframes about every second, from 0 s to 0.1 s before the end. At least 10, at most 120, so a one-hour clip gets one every 30 s (`keyframeTimes`).
  2. It measures the water analysis on every keyframe.
  3. `VideoSceneSplitter` splits the keyframes into scenes. A new scene starts when a keyframe's mean colour is far from the running scene mean: more than 0.04 in OKLab distance. The next keyframe must be that far too.
  4. Per scene, it runs depth inference and the water fit on at most 10 keyframes, evenly spread (`maximumFitsPerScene`).
  5. Per scene, `WaterAnalysis.sceneInliers` drops whole keyframes that stand out, for example a surface frame. At least half always stay.
  6. `WaterAnalysis.sceneMean` and `RestorationPlan.sceneAverage` average the kept keyframes. Both use the same kept list.
  7. `sceneLevel()` replaces the depth map with one constant value in a 2×2 map.
  8. A scene whose fits all failed borrows the whole clip's plan.
- `VideoRestorationAnalysis.moment(at:)` gives each frame its scene. Between two scenes the values cross-fade over at most 1 s, centred between the two keyframes (smoothstep). Each scene gets its own `make()` result, and the results mix.
- For HDR, `RestorationEngine.combined(_:moment:settings:filter:preservesHDR:)` raises the output limit to 8.
- Export runs no depth inference. The only depth inferences happen during analysis.
- If no keyframe has a usable plan, the clip uses only the UnderBlue correction (`legacyAnalysis`, the whole clip's mean).
- `RestorationEngine.combined` performs the inverse image-formation operation in a stitchable Core Image Metal kernel. Per-channel recoverability limits the physical correction before the UnderBlue finishing and intensity blend. Photo and video share this entry point.

Optical flow is disabled. Each scene has one constant-depth plan, so it has no role.

## Preview behavior

The current product has a filtered `VideoPlayer`, not a separate Before/To Be thumbnail widget. A representative 50% frame is cached for DEBUG comparison. The player and the export both take each frame's values from `moment(at:)`, so preview and export match. Preset changes build and assign a fresh video composition. A generation token stops an older asynchronous refresh from replacing the newest selection.

Before physical analysis is available, the existing UnderBlue filter composition remains usable. When analysis completes, one completed composition replaces it. Preset changes do not rerun depth inference.

## Confidence formula

The scalar physical-restoration gate is the minimum of overall fit, depth, water-fit and temporal confidence. Effective per-channel weights are:

`scalar gate × channel recoverability RGB`

This prevents a strong green/blue signal or powerful device from hiding an unrecoverable red channel. If any physical stage fails, video processing continues through the existing UnderBlue path.
