# App Store release checklist

## Xcode configuration

- Product: `HydroTone`
- Bundle ID: `com.hydrotone.app`
- Version: `1.0`
- Build: `1`
- Minimum OS: iOS 26.0
- Device family: iPhone
- Signing: Automatic, team `M3HJ7YK7N7`
- App icon: 1024×1024 PNG without alpha
- Release debug information: DWARF with dSYM
- Release validation and dead-code stripping: enabled
- Mac Catalyst and Designed for iPhone on Mac: disabled
- Non-exempt encryption: `NO` (the app contains no proprietary encryption)

The add-only Photos usage description is localised through `InfoPlist.xcstrings`. The privacy manifest declares no tracking or collected data and lists required-reason API usage for disk space, file timestamps and app-only UserDefaults.

## Before each upload

1. Increase `CURRENT_PROJECT_VERSION` for every uploaded build.
2. Increase `MARKETING_VERSION` only for a new App Store version.
3. Select **Any iOS Device (arm64)**, then Product → Archive.
4. In Organizer, run **Validate App** before **Distribute App**.
5. Retain the archive and dSYM for crash symbolication.
6. Run the physical-device matrix in `QA.md` and `VideoV2QA.md`.

## App Store Connect information still required

These values cannot be supplied by the Xcode project:

- App name availability and SKU
- Primary category: Photo & Video
- Subtitle, promotional text, description and keywords
- Support URL and privacy-policy URL
- Screenshots for required iPhone display sizes
- Age-rating questionnaire
- Copyright and review contact
- Availability, territories and price
- App Privacy answers (current implementation collects no data)
- Non-consumable product `com.hydrotone.pro`, price and review screenshot
- App Review notes explaining local processing, the one-photo/one-video trial and optional diagnostic sharing

See `AppStoreMetadata.md` for prepared Korean/English copy, screenshot captions and the recommended capture sequence.

## Crash and diagnostics intake

- TestFlight automatically shares crash reports with the developer. Review them in Xcode Organizer → Crashes and App Store Connect → TestFlight Feedback.
- App Store crash reports appear in Organizer for customers who share diagnostics with Apple.
- HydroTone's MetricKit/error summary remains on the device. The user must open Diagnostics, prepare the JSON report and explicitly share it through Mail or another destination.
- HydroTone has no automatic diagnostic upload, analytics backend or support-email transmission.
- If Organizer has no report, a customer can share the app crash log from Settings → Privacy & Security → Analytics & Improvements → Analytics Data.

## Complimentary Pro access

`com.hydrotone.pro` is a non-consumable In-App Purchase. After the app is **Ready for Distribution** and the IAP is **Approved**:

1. App Store Connect → Apps → HydroTone → In-App Purchases.
2. Open HydroTone Pro and scroll to **Offer Codes**.
3. Create a **Free Offer**, select all eligibility groups if it should work for any friend, and select territories.
4. For a few friends, create a custom code with a small redemption limit and share its redemption URL. One-time-use batches currently start at 500 codes.
5. Codes can be valid for at most six months. The unlocked non-consumable itself does not expire after redemption.

Before release, use Sandbox offer codes or TestFlight. Production custom and one-time-use codes aren't generated until both the app and IAP are approved.
