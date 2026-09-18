# Photo restoration quality spike

This phase is deliberately photo-only. Video preview, export, temporal processing and HDR policy are unchanged.

The app bundles Apple's compressed `DepthAnythingV2SmallF16P6` Core ML package. The model is derived from Depth Anything V2 Small and distributed under the Apache License 2.0. Source and model card: <https://huggingface.co/apple/coreml-depth-anything-v2-small>.

## DEBUG comparisons

Set one launch argument in the HydroTone scheme, import the same photo, and capture the preview or export:

- `--photo-pipeline=original`
- `--photo-pipeline=current`
- `--photo-pipeline=restoration`
- `--photo-pipeline=combined`

`combined` is the default. Tests or LLDB can also call `PhotoProcessor.comparisonPreviews` to render all four variants from one prepared plan. Release builds always use the combined path.

Depth inference and aggregate restoration diagnostics are emitted through Unified Logging in DEBUG builds. Diagnostics contain only timings, scalar statistics, fitted RGB parameters, confidence, and clamp percentages; no filenames or pixel values are logged.
