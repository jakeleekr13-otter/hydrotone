# Video V2 implementation

Video V2 is a SeaThru-inspired depth-aware restoration path, not SeaThru or SeaThru-NeRF.

## Architecture

- `DeviceCapabilityProfiler` measures `.all` for the provisional first-clip policy, then benchmarks `.cpuAndNeuralEngine` at utility priority after the preview analysis is ready. It caches the faster policy for the current OS major version and model/profile version, so the second model load never blocks the first visible preview.
- `VideoSourceProfile` records duration, display size, frame rate, codec, bit depth, dynamic range, approximate bitrate and a pixel-throughput workload class without decoding the clip.
- `ProcessingPolicyBuilder` combines device capability, source workload, runtime thermal state and preview/export purpose. It controls only analysis-map size, depth cadence, environment-check cadence and concurrency.
- `VideoRestorationAnalyzer` examines frames near 10/30/50/70/90 percent. It uses confidence-weighted medians for scene-level RGB parameters and never averages unrelated depth maps.
- `TemporalRestorationSession` belongs to one sequential export. It performs 2–5 depth inferences per second, holds a target depth map, approaches it with a time-based EMA, robustly smooths water parameters, and resets only after two persistent keyframes with at least two changed environment signals.
- `RestorationEngine` performs the inverse image-formation operation in a stitchable Core Image Metal kernel. Per-channel recoverability limits physical correction before the existing HydroTone finishing and intensity blend.

Optical flow is deliberately disabled. Low-resolution Vision flow will only be added if real footage demonstrates a material improvement over the current higher-cadence inference plus smoothing path.

## Preview behavior

The current product has a filtered `VideoPlayer`, not a separate Before/To Be thumbnail widget. A representative 50% frame and its restoration plan are cached for DEBUG comparison. The player uses timestamp-indexed immutable sample plans. Preset changes build and assign a fresh video composition; a generation token prevents an older asynchronous refresh from replacing the newest selection.

Before physical analysis is available, the existing HydroTone filter composition remains usable. When analysis completes, one completed composition replaces it. Preset changes do not rerun depth inference.

## Confidence formula

The scalar physical-restoration gate is the minimum of overall fit, depth, water-fit and temporal confidence. Effective per-channel weights are:

`scalar gate × channel recoverability RGB`

This prevents a strong green/blue signal or powerful device from hiding an unrecoverable red channel. If any physical stage fails, video processing continues through the existing HydroTone path.
