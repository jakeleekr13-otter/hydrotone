# Video cleanup prototypes

These are two measured components for video export: a hardware temporal denoiser and a particle (marine snow) filter. They are NOT in any Xcode target yet. The export loop (`HydroTone/Export/VideoExporter.swift`) will adopt them later.

## Components

| File | What it does |
|---|---|
| `TemporalDenoiser.swift` | Wraps Apple's `VTTemporalNoiseFilter` (VideoToolbox, iOS 26+). When the device does not support it, frames pass through unchanged. |
| `ParticleFilter.swift` | Removes small, bright specks that are not in the same place in the neighbouring frames after motion is removed. Our own logic. Motion is estimated by block matching in Metal. |

### TemporalDenoiser facts (measured on a Mac M3)

- The filter only accepts compressed 420 formats: `&8v0` (lossless 8-bit) and `&xv0` (lossless 10-bit, HDR). So the asset reader must output one of them.
- It needs 1 previous frame and 2 next frames, so output lags input by 2 frames.
- Speed at 1080p is about 150 fps. Core Image reads its output with no difference.
- HLG and PQ 10-bit work.
- Recommended strength is 0.5. At 1.0, small moving fish start to fade.

### ParticleFilter facts (measured on a Mac M3, 1080p60 dive clips)

- On its own, it removes 43-71% of the drifting specks on 3 of the 4 test segments. The fourth has about 1 speck per frame, and there it removes 21%.
- It keeps 99-100% of small subjects and changes under 0.1% of pixels.
- Particle-then-denoise removes the most (58-92%), but the denoiser costs dark small detail. In the fish school segment, only 70-76% of it is kept.
- Speed:
  - 1080p: 126-204 fps. The range comes from the fanless Mac's GPU clock.
  - 4K: 63-67 fps. The input was upscaled by the reader.
  - Not measured on an iPhone.
- Output lags input by 3 frames.
- Fish survive in both particle-only and particle-then-denoise. The crops were checked by eye. See `results/PARTICLE_REPORT2.txt`.

### Integration notes

- Order: particles, then (optionally) denoise, then colour correction. Colour gains and clarity amplify specks and noise.
- Wrap each frame's push and render in `autoreleasepool`. Otherwise memory grows about 16.6 MB per 1080p frame.
- Keep presentation times from the source. Handle the look-ahead at the end of the clip with `finish()`.

## Benches

- `particle-bench/`: speck metric, segment runs and speed tests. Build it with `particle-bench/build.sh`, then run `particle-bench/run_all.sh`.
- `denoise-bench/`: strength sweep, speed, Core Image check and HDR check. Build it with `denoise-bench/build.sh`, then run `$HT_PROTO_OUT/bench [clip1_coral|clip2_anemone|clip3_school]`.

Environment variables:

| Variable | Default |
|---|---|
| `HT_EVAL_DATA` (clips) | `DeveloperMedia/` |
| `HT_PROTO_OUT` (binaries and outputs) | `$TMPDIR/hydrotone-video-cleanup/...` |

## Results

The measured logs and reports are in `results/`:

- `DENOISE_REPORT.txt`
- `denoise_run_all.log`
- `particle_run1_cpu_motion.log` (first prototype, CPU motion, 31 fps)
- `particle_run2_gpu_motion.log` (Metal motion)
- `run2_speed1080_final.log`
- `run2_speed4k.log`
- `PARTICLE_REPORT2.txt`
