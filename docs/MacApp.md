# UnderBlue for Mac — plan

Status: decisions made 1 Oct 2026. Nothing built yet.

## Goal

- A separate Mac app with its own bundle ID and its own price.
- Selling point: one batch job for many photos and videos at once.
- Use the Mac's extra memory, GPU and Neural Engine for more parallel work.

## Facts this plan rests on (read 1 Oct 2026)

| Fact | Source |
|---|---|
| The project has one iPhone-only app target. Catalyst and "Designed for iPhone" are off. | `scripts/create_project.py`, `project.pbxproj` |
| Targets use synchronized folders. The project file is generated. | `create_project.py` |
| `UnderBlue/Processing/` has no UIKit. The colour harness already builds it for macOS. | `scripts/color-eval/common.sh:29-33` |
| 11 files touch platform APIs: `UIApplication` background tasks and memory warnings, `navigationBarTitleDisplayMode`, `fullScreenCover`, `PhotosPicker`, `PHPhotoLibrary`, the share inbox. Not all are iOS-only; the build in stage 1 decides. | grep on `UnderBlue/` |
| Batch takes photos only, at most 10. It exports one at a time. | `BatchModel.swift:8`, `:149` |
| `PhotoProcessor` is one actor, so all photo work runs one job at a time. | `PhotoProcessor.swift:19` |
| The performance tier stops at "memory ≥ 5 GB → high". It was tuned for iPhone. | `VideoProcessingPolicy.swift:79` |
| The same Core Image code renders differently on Mac and iOS. | memory `mac-version-plan`, commit 46958c3 |

## Structure

- Same repo, same Xcode project. A new target `UnderBlueMac` is added in `create_project.py`.
- Shared code: `UnderBlue/Processing`, `Models`, `Export`, `Diagnostics`, `Commerce`. Both targets compile it.
- Mac-only code: a new folder `UnderBlueMac/` (app entry, Mac views, file import, folder export).
- iOS-only files stay in `UnderBlue/` and are excluded from the Mac target by a per-file `membershipExceptions` list. (A folder path does not work there; see memory `synchronized-group-exclusion`.)
- Small iOS-only calls inside shared files go behind `#if os(iOS)`.
- Native macOS target with SwiftUI. Not Catalyst: Catalyst carries the iPhone layout and blocks a Mac-style batch window.

## Mac interface

SwiftUI on macOS draws native Mac controls. The Mac app gets:

- One main window: sidebar with the queue, centre with a before/after preview, right inspector with Look, preset and Custom sliders.
- Toolbar: Add, Start, Pause, Stop, output folder.
- Drag and drop from Finder: files and whole folders.
- Menu bar commands and keyboard shortcuts (⌘O add, ⌘R start, ⌘. stop, ⌘, settings).
- A Settings window: output folder, photo format, HDR, parallel jobs.
- Progress on the Dock icon and a notification when the batch ends.

Views that can be reused after small changes: `CustomAdjustmentControls`, `ZoomablePreview`, `ProView`, `DiagnosticsView`.

## Stages

Each stage ends with one artifact that can fail.

| # | Stage | Work | Artifact |
|---|---|---|---|
| 0 | Decisions | Done 1 Oct 2026. | Decisions table below |
| 1 | Target | Add the `mac` scope to `create_project.py`: `SDKROOT macosx`, Mac bundle ID, App Sandbox entitlements. Empty window. | `xcodebuild` build passes for `UnderBlueMac` and for `UnderBlue` (iOS) |
| 2 | Platform seams | Put background task and memory warning behind one small lifecycle type. Split iOS-only modifiers. | Both builds pass; `git diff --stat` shows no change in `Processing/` |
| 3 | Batch engine (shared) | Stage pipeline (see "Batch engine design"): photos and videos mixed, no 10-item cap, per-item state, cancel, resume, name clashes through `ExportNaming`. | Mac unit test: 3 photos + 2 videos → 5 files, each passes `OutputValidator`, finished in queue order |
| 4 | Mac UI | Window, sidebar, inspector, toolbar, drop, menus, Settings, security-scoped bookmark for the output folder. | Screenshot of the app running a 20-item mixed batch |
| 5 | Commerce | Mac price model and product IDs. Own StoreKit config. Own trial key. | Manual sandbox check (no StoreKit tests, memory `no-storekit-tests`) |
| 6 | Mac colour numbers | Run the gate and m5 as Mac product numbers. Compare one Mac app export with the harness render. Decide on Mac-only reference smoothing. | Gate and m5 output lines; ΔE of app export vs harness |
| 7 | Performance | Mac tier in `VideoProcessingPolicy`: parallel job count, memory limit, encoder sessions. Only after the algorithm is final (memory `algorithm-before-performance`). | Timing table on one fixed set: photos per minute, video speed vs real time, before and after |
| 8 | Release | New App Store Connect app, Mac screenshots, metadata, privacy manifest, sandbox review. | Build accepted in App Store Connect |

Stages 1–2 change only build setup and seams. Stages 3 and 4 can run in parallel after stage 2.

## Batch engine design (stage 3)

Facts from the code (1 Oct 2026):
- `VideoExporter.export` handles one frame at a time: read, Core Image render, append. Each step waits for the one before it.
- Video work has two phases. Analysis is mostly CPU: on iPhone 17, 24.9 s, of which depth on the Neural Engine was about 0.6 s (Debug build, memory `video-open-trace`). Export is GPU render plus the hardware encoder.
- `VideoExporter` and `PhotoProcessor` are actors, so one instance runs one job at a time.

Design: a stage pipeline, not a free-for-all.
- Each item goes through `analyze → export → save`.
- Each stage has its own job limit. Default: analysis 1, video export 1, photo export N (limited by memory).
- So while video 1 exports on the GPU, video 2 analyses on the CPU. Results still finish one by one, in order.
- The limits are numbers in the Mac performance tier. Stage 7 sets them from measurement: 1 vs 2 video exports at once, on the same set of clips.
- Memory is the hard limit: a job starts only if its estimated memory fits.

Why not "all videos at once": the first result comes late, a cancel loses more work, and memory use grows with the count.
Why not "strictly one at a time": the CPU idles during export, and the GPU idles during analysis.

## Decisions (Jake, 1 Oct 2026)

| # | Question | Answer |
|---|---|---|
| 1 | Bundle ID | `com.underblue.mac` |
| 2 | Price model | Free download + in-app purchase. Proposed product ID `com.underblue.mac.pro`. Trial: yes, same as iOS — reuse `TrialStore` (one free photo export, one 10 s video export, per device). No batch in the trial: batch is Pro only, and the paywall says so. |
| 3 | Lowest macOS | macOS 26, Apple silicon only. Depth estimation stays. |
| 4 | Store | Mac App Store only (sandboxed) |
| 5 | Save target | User chooses: a folder or the Photos library. Setting in Settings, default open. |
| 6 | Share extension | Yes, like the iPhone app: share from Photos and Finder into UnderBlue. |

Effects on the stages:
- Stage 1 adds the sandbox entitlements: user-selected files (read-write), Photos library, app group.
- Stage 1 also adds the Mac share extension target `UnderBlueMacShare`.
- Stage 4 adds the save-target choice. The Photos library path reuses `PhotoLibrarySaver`.
- Stage 5 uses the new product ID. The Mac paywall names batch (many photos and videos at once) as the Pro feature.

## Risks

- Mac and iOS render differently. Every colour change needs one check on each platform.
- Sandbox: the output folder needs a security-scoped bookmark, or writes fail after a relaunch.
- Memory: many 4K/HDR videos at once can exhaust memory. The queue must limit by memory, not only by count.
- A shared batch engine also changes the iPhone batch. iOS keeps its own limits.
