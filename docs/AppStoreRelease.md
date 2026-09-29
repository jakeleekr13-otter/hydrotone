# App Store release checklist

Last reviewed: 2026-09-25

## Xcode configuration

- Product: `UnderBlue`
- Bundle ID: `com.underblue.app`
- Version: `1.0`
- Build: `1`
- Minimum OS: iOS 26.0
- Signing: Automatic, team `M3HJ7YK7N7`
- Share extension: `UnderBlueShare`, bundle ID `com.underblue.app.share`, embedded in the app
- App Group: `group.com.underblue.app`, in both the app and the extension entitlements. Automatic signing registered both on 28 Sep 2026. The old App Store profile has no App Group, so the next archive creates a new one.
- App icon: 1024×1024 PNG without alpha
- Release debug information: DWARF with dSYM
- Release validation, whole-module optimization and dead-code stripping: enabled
- Non-exempt encryption: `NO` (the app contains no proprietary encryption)
- App category in the generated Info.plist: `public.app-category.photography`

All four targets—`UnderBlue`, `UnderBlueShare`, `UnderBlueTests` and `UnderBlueUITests`—are explicitly limited to:

- Supported platforms: `iphoneos iphonesimulator`
- Targeted device family: iPhone (`1`)
- Mac Catalyst: disabled
- Designed for iPhone/iPad on Mac: disabled
- Designed for iPhone/iPad on Apple Vision: disabled

The latest device build was verified with `UIDeviceFamily = [1]`, `CFBundleSupportedPlatforms = ["iPhoneOS"]` and `LSRequiresIPhoneOS = true`. Xcode may still list iPad simulators as run destinations because iPhone-only apps can run in iPadOS compatibility mode. This does not enable native iPad support and does not require iPad screenshots.

The add-only Photos usage description is localised through `InfoPlist.xcstrings`. The privacy manifest declares no tracking and lists required-reason API usage for disk space, file timestamps and app-only UserDefaults. The share extension calls none of the required-reason APIs; its code was checked on 28 Sep 2026. So it has no privacy manifest of its own. UnderBlue has no automatic analytics or diagnostic upload.

## Prepared App Store Connect values

- App name: `UnderBlue` (availability must be confirmed in App Store Connect)
- Platform: iOS
- Primary language: English (U.S.)
- Suggested SKU: `UNDERBLUE-IOS-001`
- Subtitle: `Underwater colour, restored`
- Primary category: Photo & Video
- Secondary category: None
- App price: Free
- Distribution: Public
- Version release: Manual release recommended for 1.0
- Content rights: no bundled or streamed third-party content
- Sign-in/demo account: not required
- Regulated medical device: No
- Custom EULA: use Apple's standard EULA

The complete English and Korean descriptions, promotional text, keywords and review notes are in `AppStoreMetadata.md`.

## Public support and privacy pages

- Support URL: <https://jakeleekr13-otter.github.io/underblue-support/support/>
- Privacy Policy URL: <https://jakeleekr13-otter.github.io/underblue-support/privacy/>
- Public website repository: <https://github.com/jakeleekr13-otter/underblue-support>
- Support email: `support@enheart.me`
- Privacy email: `privacy@enheart.me`

Both pages are publicly available over HTTPS. Their email addresses are clickable `mailto:` links. The repository's `main` branch blocks force pushes and deletion; only the owner has direct repository access.

## App Privacy declaration

App Store Connect is intentionally configured conservatively as collecting diagnostics because a user may explicitly email a generated report to the developer.

- Data collection: Yes
- Crash Data: collected only when the user explicitly shares a report
- Performance Data: collected only when the user explicitly shares a report
- Other Diagnostic Data: collected only when the user explicitly shares a report
- Purpose: App Functionality (customer support and reliability)
- Linked to the user: No. Set in App Store Connect on 29 Sep 2026 (all four types: App Functionality only). This needs the support process below that keeps a report apart from the sender's email.
- Tracking: No
- Advertising or marketing use: No
- Photos or Videos: collected only when the user explicitly emails a photo or video to support (added 29 Sep 2026)
- Location: Not collected
- Device ID: Not collected
- Automatic upload: No

If a diagnostic attachment is retained together with the sender's email address, mark it as linked to the user. Mark it as not linked only if the support process separates the report from the sender identity and does not attempt to reconnect them. Keep the App Store Connect response and the public privacy policy consistent with the actual support workflow.

## Screenshots and promotional assets

Five upload-ready English iPhone screenshots are in `AppStoreAssets/Screenshots/en-US/final-v2`. Each is a flattened 1320×2868 RGB JPEG without alpha.

1. `01-before-after.jpg`
2. `02-deep-dive.jpg`
3. `03-video.jpg`
4. `04-export.jpg`
5. `05-video-before-after.jpg`

The first image is an authentic same-frame before/after comparison. The source capture and the corrected capture were produced by the app from developer-owned media. UIEB benchmark images are excluded because the dataset is academic/non-commercial and forbids redistribution.

An App Preview video is optional and is intentionally omitted from the first submission.

The optional 1024×1024 promoted-IAP image is `AppStoreAssets/IAP/UnderBluePro-1024.png`. It is not the IAP review screenshot. The required review screenshot must show the real UnderBlue Pro screen, the localised App Store price, feature list, one-time purchase wording and Restore Purchase button.

## UnderBlue Pro In-App Purchase

- Type: Non-Consumable
- Reference name: `UnderBlue Pro`
- Product ID: `com.underblue.pro`
- English display name: `UnderBlue Pro`
- English description: `Unlimited photos, full video, 4K and HDR`
- Availability: match the app's selected territories
- App Store Server Notifications URL: leave blank; UnderBlue has no server
- Family Sharing: leave off for the first release unless it is explicitly tested and accepted as an irreversible setting

The production price is USD 14.99 (Jake, 29 Sep 2026). The local StoreKit configuration's USD 4.99 value is test data only. The first IAP must be included in the same App Review submission as app version 1.0.

## Remaining App Store Connect work

Jake reported on 29 Sep 2026 that every item except the screenshots is done in App Store Connect.

- [x] Confirm that the `UnderBlue` name is available and create/verify the app record.
- [x] Confirm the final SKU before creating the record; it cannot be changed afterward.
- [x] Accept the Paid Apps Agreement and complete banking and tax information.
- [x] Complete EU Digital Services Act trader status and any territory-specific compliance questions.
- [x] Choose the app territories; exclude a territory temporarily if App Store Connect requests documentation that is not ready.
- [x] Complete the age-rating questionnaire with no mature, social, advertising, gambling or unrestricted-web content; expected result is 4+.
- [x] Enter the copyright owner using the Apple Developer account's legal name.
- [x] Enter a reachable App Review contact name, email and international-format phone number.
- [x] Create `com.underblue.pro`, choose its production price and tax category, and add its localisation.
- [x] Capture and upload the real UnderBlue Pro purchase-screen review screenshot.
- [ ] Upload the five iPhone screenshots.
- [x] Paste the prepared description, promotional text, keywords and App Review notes.
- [x] Publish the App Privacy answers and verify the Product Page Preview.
- [x] Upload and select a fresh archive built from the final source.
- [x] Add both iOS app version 1.0 and UnderBlue Pro to the same draft submission.

## Before each upload

1. Increase `CURRENT_PROJECT_VERSION` for every build previously uploaded to App Store Connect. Build `1` can be reused only if it has never been uploaded.
2. Increase `MARKETING_VERSION` only when creating a new App Store version.
   Change both numbers in the `UnderBlue` **and** `UnderBlueShare` targets. A mismatch fails App Store validation.
3. Run the physical-device matrices in `QA.md` and `VideoV2QA.md`.
4. Select **Any iOS Device (arm64)**, then Product → Archive.
5. In Organizer, run **Validate App** before **Distribute App**.
   Confirm the archive contains `PlugIns/UnderBlueShare.appex`, and that both profiles include the App Group.
6. Retain the archive and dSYM for crash symbolication.
7. Confirm the uploaded build reports iPhone-only device family and no Mac, Catalyst or Vision availability.

Do not upload the existing local archive blindly: create a fresh archive after the latest diagnostics, support-site and platform-setting changes. If build `1` has already reached App Store Connect, increment it before archiving.

## Current local verification

- iPhone device build: succeeded
- App, unit-test and UI-test `build-for-testing`: succeeded
- Full unit suite from the latest functional run: 44 tests executed, 0 failures, 2 physical-device-only Core ML tests skipped in Simulator
- Supported-target build settings verified for Debug; the same settings are generated for Release

## Crash and diagnostics intake

- TestFlight shares available crash reports through Xcode Organizer and App Store Connect TestFlight feedback.
- App Store crash reports appear in Organizer when customers share diagnostics with Apple.
- UnderBlue's MetricKit/error summary remains on the device until the user opens Diagnostics, prepares the JSON report and explicitly shares it.
- The local report includes privacy-safe aggregated photo/video restoration fallback events as well as common import, preview, export, save and purchase failures.
- The report excludes photos, videos, filenames, file paths, location, per-pixel data, raw error descriptions and `userInfo`.
- UnderBlue has no automatic diagnostic upload, analytics backend or automatic support-email transmission.
- Customers should email private diagnostic reports to `support@enheart.me`, not attach them to a public GitHub issue.

## Complimentary Pro access

`com.underblue.pro` is a non-consumable In-App Purchase. After the app is **Ready for Distribution** and the IAP is **Approved**:

1. App Store Connect → Apps → UnderBlue → In-App Purchases.
2. Open UnderBlue Pro and scroll to **Offer Codes**.
3. Create a **Free Offer**, select the intended eligibility groups and territories.
4. For a few friends, create a custom code with a small redemption limit and share its redemption URL. One-time-use batches currently start at 500 codes.
5. Codes can be valid for at most six months. The unlocked non-consumable itself does not expire after redemption.

Before release, use Sandbox offer codes or TestFlight. Production custom and one-time-use codes are not generated until both the app and IAP are approved.
