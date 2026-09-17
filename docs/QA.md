# QA matrix

Status reflects automated tests in this repository. “Device QA” is deliberately not marked complete without physical media/hardware.

| Area | Coverage | Status |
|---|---|---|
| Photo formats | JPEG portrait orientation; generated HEIC; Display P3 output; preview/export pixel comparison | Automated pass |
| Filter behavior | Original/0%, 50%, 100%; neutral black/white; red restoration | Automated pass |
| SDR codecs | H.264 and HEVC | Automated pass |
| Resolution | 1080p; generated 4K; no upscaling; portrait dimensions | Automated pass |
| Timing | 24/30/60 fps; variable presentation timestamps; 10-second trial boundary | Automated pass |
| Audio | AAC audio present and absent; audio track count and duration | Automated pass |
| Orientation | Portrait metadata is baked; output transform is identity; source/output pixels compared | Automated pass |
| Cancellation | Before start and during export; no partial output remains | Automated pass |
| Long export | Two-minute 3,600-frame sequential export; bounded post-warmup memory after output-pool cap | Automated pass |
| HDR input/output | HLG and PQ 10-bit detection; HDR→SDR; HLG/PQ Main10 signaling; highlight values above SDR white | Automated pass on simulator codecs |
| Dolby Vision | No output claim; base HDR compatibility only | Device QA required |
| Trial | One photo; one video; 10 seconds; rollback after failure/interruption; real Keychain round trip | Automated pass |
| StoreKit | Product load, purchase, current entitlement, restore, refund, pending approval, cancellation and simulated error | Automated StoreKit pass |
| Localization | English source/fallback; Korean, Japanese, Simplified Chinese, Traditional Chinese; localized errors and Photos usage string | Automated bundle pass |
| Diagnostics | Failure classification, nested errors, bounded retry, privacy sanitization, burst aggregation and report size | Automated pass |
| UI | Home, paywall, Photos picker, photo editor, compare, export sheet, save and consumed-trial gate; landscape video editor | Simulator UI test |

## Physical-device release matrix

Run these before an App Store release:

- JPEG, HEIC and Adaptive HDR photos from current iPhones; verify actual Photos metadata and wide-color rendering.
- GoPro, DJI Osmo Action and Insta360 samples: H.264/HEVC, 8/10-bit, 1080p/4K, 30/60 fps, portrait/landscape, variable timing, with/without audio.
- iPhone HLG/Dolby Vision, external-camera HLG/HDR10 and unusual compatible Dolby Vision clips. Inspect every result in Photos, QuickTime/AVAsset and a metadata tool. Confirm HydroTone never labels output Dolby Vision.
- Multi-minute and long 4K exports on the oldest supported iPhone. Measure peak memory, thermal behavior, sustained frame rate and free-space estimates with Instruments.
- Background, lock, phone call, memory warning, thermal critical, disk-full and Photos permission-denied flows. Confirm cleanup and trial rollback.
- VoiceOver, Dynamic Type accessibility sizes, landscape layout, long Japanese/Chinese strings and every supported language in pseudolocalization.
- Real App Store sandbox: not purchased, buy, cancel, Ask to Buy/pending, interrupted transaction, restore, refund/revocation and offline StoreKit.
- TestFlight crash/hang: detach the debugger, reproduce, confirm symbolication in Xcode Organizer and inspect the user-shared local diagnostic report.
