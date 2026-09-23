# Video V2 real-world QA matrix

None of the following is considered passed until the named footage has actually been processed on a physical iPhone and inspected during playback.

## Capture sources

- iPhone SDR and HLG/Dolby Vision base-layer-compatible footage
- GoPro H.264 and HEVC
- DJI action camera H.264 and HEVC
- Insta360 exported flat and standard-color footage

## Water and lighting

- Clear tropical blue water: snorkeling, 5–10 m, 10–20 m and deeper
- Green water or quarry/lake footage
- Reef, sand, open water, wreck and cave/overhang
- Low visibility and strong particulate backscatter
- Significant red-channel loss
- Dive light and night footage
- Mixed ambient/artificial lighting
- Above-water → underwater and underwater → above-water transitions

## Motion and temporal behavior

- Static tripod-like shot
- Slow and fast pan
- Moving diver and fish
- Bubbles crossing most of the frame
- Temporary close occlusion
- Exposure flash or dive-light sweep

Check for color pumping, one-frame parameter jumps, delayed environment resets, false resets, depth-edge dragging and preset-refresh staleness.

## Media matrix

- 1080p30 SDR
- 1080p60 SDR
- 4K24/30 SDR
- 4K60 SDR
- 4K30 HLG/PQ
- 4K60 HDR where the device/source support it
- Portrait orientation, variable timing, with/without audio
- Short clips, multi-minute clips and a long thermal/memory run

For each representative scene compare Original, HydroTone only, physical restoration only, combined, depth visualization and confidence visualization using the DEBUG comparison method. Record device model, OS, source metadata, selected policy, export FPS, peak memory and thermal transitions.
