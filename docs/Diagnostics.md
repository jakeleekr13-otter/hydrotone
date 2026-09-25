# Error handling and diagnostics review

## Assessment

The original implementation handled many failures at the user interface boundary, cleaned partial exports, and wrote underlying errors to `Logger` in debug builds. It was not production-ready for diagnosis: arbitrary error descriptions were marked public, there was no error taxonomy, frequent failures could create repeated alerts/logs, no crash/hang/energy diagnostics were retained, and the app offered no privacy-controlled way to share a diagnostic report.

The current implementation follows Apple's native diagnostics path without adding an analytics SDK or backend:

- `Failure` maps expected Foundation, AVFoundation, Photos, Keychain and app failures into stable, actionable categories. It walks a short underlying-error chain but retains only an allowlisted domain and numeric code. It never retains `localizedDescription`, `userInfo`, URLs, paths, filenames, media contents, StoreKit transaction data, or Apple Account data.
- `DiagnosticRecorder` uses Unified Logging for new error groups. Its public fields come from fixed enums/domain allowlists and numeric codes. Repeated identical failures are counted in one-minute buckets instead of writing every occurrence.
- The recorder keeps at most 64 aggregated error groups for seven days. Files use data protection, are excluded from backup, and stay in the app container.
- MetricKit receives Apple's crash, hang, CPU, disk-write, energy and performance reports. Reports stay local, are capped at one MiB each, and are pruned to six reports/seven days.
- The Diagnostics screen explains the report, prepares it only when requested, lets the user inspect/share it with the system share sheet, and lets the user delete it. No report is uploaded automatically.
- TestFlight/App Store crash reports remain available through Xcode Organizer when the user shares diagnostics with Apple. Release archives and dSYMs must be retained for symbolication.
- TestFlight crash reports are shared automatically with the developer. App Store crash availability depends on the customer's analytics-sharing setting. These reports are reviewed in Xcode Organizer rather than delivered as HydroTone support email.
- The in-app diagnostic JSON is never sent automatically. The user explicitly chooses Mail or another destination from the system share sheet.
- `OSSignposter` measures video exports. The exporter cancels on critical thermal state or memory pressure and removes partial output.

This is aligned with Apple's guidance to use Unified Logging with privacy controls, signposts for important intervals, MetricKit for on-device performance/diagnostic reports, and Xcode Organizer for symbolicated crash reports. The local report is an optional support aid; it does not replace Organizer crash reports or Instruments profiling.

## Frequent-failure policy

| Condition | User behavior | Automatic behavior |
|---|---|---|
| iCloud/network interruption during import, inspection or product loading | One clear retry message if it still fails | Retry read-only work once (up to three attempts supported by the bounded helper) |
| Media services reset / decoder temporarily unavailable | Ask the user to wait and retry | Retry read-only inspection/preview once; never restart an export automatically |
| Unsupported or corrupt codec/media | Explain that the item cannot be opened/supported | No repeated attempt |
| Low storage | Ask the user to free space | Check before import and export; remove incomplete files |
| Photos permission denied | Explain how to enable add-only access | Keep the validated export so saving can be retried |
| Memory warning | Explain that memory is low | Cancel an active export and clean the partial file |
| Critical thermal state | Ask the user to let the iPhone cool | Refuse a new export or cancel at the next bounded frame checkpoint |
| Playback failure | Show one actionable alert and a Retry Preview control | Pause repeated preview rendering; aggregate repeated diagnostics |
| Purchase cancellation | No error alert | Never unlock Pro and never retry automatically |
| Pending purchase | Explain that approval is pending | Transaction updates unlock Pro only after verification |
| Keychain unavailable while locked or restricted | Ask the user to unlock and retry | Fail closed; do not grant or consume trial state |

Automatic retry is limited to idempotent reads. Photo saving, purchases, restore, trial commitment and exports are not automatically repeated because doing so could duplicate a user-visible side effect or consume resources unexpectedly.

## Restoration fallback codes

`kind = restorationFallback`, `domain = HydroTone`. The code tells which step fell back to the standard correction. Codes are stable; new stages only append.

| Code | Stage | Meaning |
|---|---|---|
| 1 | photoAnalysis | Photo depth or water-model fit failed (older builds; cause unknown) |
| 11-15 | photoAnalysis + cause | The same, with the cause: 1 missing model, 2 invalid depth, 3 depth too flat, 4 water fit failed, 5 restoration kernel unavailable |
| 2 | photoRender | Photo restoration render failed |
| 3 | videoInitialAnalysis | One video sample's depth or water fit failed |
| 4 | videoTemporalAnalysis | Older builds only (per-frame video analysis) |
| 5 | videoRender | Video preview or export restoration render failed |
| 6 | videoSceneAnalysis | The whole video scene analysis failed; the clip used the standard correction |
| 7 | finishKernel | The finishing colour kernel did not compile; every output used the plain colour-matrix fallback |
| 8 | photoNoUsablePixels | The photo had no usable pixels for analysis (very dark or blown out) |

Memory-pressure and thermal events are saved immediately, and the whole summary is saved when the app moves to the background.

## Operational checklist

Before release:

1. Keep every App Store/TestFlight archive and dSYM in Xcode Organizer.
2. Test detached-from-debugger crashes, hangs, memory pressure, thermal pressure and disk-full behavior on physical iPhones.
3. Review Console output for `subsystem == "com.hydrotone.app"`; verify no media names or paths appear.
4. Review an exported diagnostic JSON before sharing and confirm the screen disclosure remains accurate after changing metrics.
5. Triage frequency by `operation + kind + domain + code`, then reproduce with the same media class. Do not add media identifiers to correlate users.
6. If a future backend is added, make diagnostic upload opt-in, document retention/deletion, update App Privacy disclosures, and obtain a separate product decision before enabling it.

Apple references:

- [Generating log messages and redacting sensitive data](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code)
- [Unified Logging](https://developer.apple.com/documentation/os/logging/)
- [MetricKit](https://developer.apple.com/documentation/metrickit)
- [Acquiring crash reports and diagnostic logs](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs)
- [Analyzing a crash report](https://developer.apple.com/documentation/xcode/analyzing-a-crash-report)
- [Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)
