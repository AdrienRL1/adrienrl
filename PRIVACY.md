# Privacy Policy — AppDrop

Last updated: 2026-06-04

## TL;DR

AppDrop collects nothing about you. It has no account, no analytics, no tracking, no telemetry, and stores no personal information. Everything it saves stays on your device.

To work, it contacts a small number of public services — and only when an action you take requires it: the catalog/content host, the IPA file host, the app's update check, and (only if you choose to) a moderation server when you send feedback or share an app.

## What AppDrop stores locally

Saved on your device only, in standard iOS containers:

- **Preferences** (NSUserDefaults) — iOS-version min/max, sort order, device-class filter, language override, your chosen theme, list-vs-grid and columns-per-row, and the "show Favorites on Home" toggle.
- **Favorites, collections & download-later queue** — the apps you star, the named folders you create, and the apps you queue for later. Your organization choices, nothing else.
- **Home-screen layout** — the order and size of your home tiles.
- **Onboarding flag** — a single boolean: whether you've seen the "IPA Installer Console required" notice.
- **Install job history** (Caches directory, plist) — names + URLs + states of the last 24 hours of install attempts. Auto-purged after 24 h.
- **Catalog database** (Caches directory) — `appdrop_catalog.db`, downloaded on first launch and refreshed when the hosted copy changes. A read-only snapshot of the public stuffed18 catalog plus localized descriptions.
- **Cached lists** (Caches directory) — the latest `revival.json` ("Works Today") and `mods.json` (Modded) for the next launch.
- **Icon cache** — cleared on Home button or via Settings.

None of the above leaves your device.

## What AppDrop sends to third parties

| When you… | AppDrop contacts | What gets sent | Why |
|---|---|---|---|
| Tap **Install** on an app | `archive.org` (then CDN nodes `dn*.ca.archive.org` / `ia*.us.archive.org`) | HTTP GET for the public .ipa URL | Download the IPA file |
| Open an app before downloading (FairPlay check) | `archive.org` | A small HTTP **range** request (first bytes only) | Detect DRM-encrypted builds without a full download |
| Scroll the catalog | `stuffed18.github.io` | HTTP GET for each visible icon thumbnail | Display the app icon |
| Launch the app / first run | `adrienrl1.github.io` | HTTP GET for `catalog.db.gz`, `revival.json`, `mods.json` | Download & refresh the catalog and the Works-Today / Modded lists |
| (Automatically, at most once per hour) | `api.github.com` | HTTP GET of the latest GitHub Release info | Check whether a newer AppDrop version exists |
| **Send feedback** | `appdrop-feedback.adrienruestlorquet.workers.dev` | The feedback text you write | Deliver your message (held for manual review) |
| **Share an app** (optional) | `appdrop-feedback.adrienruestlorquet.workers.dev/upload` | The .ipa file you pick + the title / category you enter | Submit it for manual moderation before anything is published |
| Download where local DNS is blocked | Google DNS-over-HTTPS (`8.8.8.8`) | Only the hostname being resolved (e.g. `archive.org`) | Resolve the host when your network blocks its DNS |
| Tap the optional tip link | opens `paypal.me` in Safari | — (you leave the app) | Optional donation |

Each third party has its own privacy policy:

- **archive.org** — https://archive.org/about/terms.php
- **GitHub** (Pages `stuffed18.github.io` / `adrienrl1.github.io`, and `api.github.com`) — https://docs.github.com/en/site-policy/privacy-policies/github-privacy-statement
- **Cloudflare Workers** (the feedback / upload endpoint) — https://www.cloudflare.com/privacypolicy/
- **Google Public DNS** (DoH) — https://developers.google.com/speed/public-dns/privacy

AppDrop sends no API key, no device ID, no IDFA, no email, no tracking cookie. The only thing those servers see is the normal network metadata of your request (your IP, the request path). The feedback / upload server is the only one that receives anything you type or choose — and only when you explicitly send feedback or submit an app.

## What AppDrop does NOT do

- No analytics (no Firebase, Sentry, Mixpanel, Apple AppAnalytics)
- No advertising, no ad SDKs
- No social-network SDKs
- No fingerprinting
- No location services
- No microphone, camera, contacts or photo-library access
- No push notifications
- No iCloud sync
- No keychain access
- No in-app purchases / payments (the tip link just opens PayPal in Safari)

When you "Share an app," you pick an `.ipa` through AppDrop's own file browser — it never reads your Photos, contacts, or anything you don't explicitly select.

## Data retention

- **Locally:** install-job history auto-expires after 24 hours; the catalog and cached lists refresh in place. Everything else persists until you delete the app.
- **Feedback / shared apps:** submissions go to the moderation server (backed by the project's GitHub) and are reviewed by a human before anything is published. Approved shared apps become part of the public Modded / Works-Today lists; rejected ones are discarded.
- **Third parties:** their own retention policies apply. We don't control what archive.org, GitHub, Cloudflare or Google log on their side.

## Your rights

AppDrop stores nothing about you remotely, so there's nothing to export or delete on our side. To erase the local data, uninstall AppDrop — iOS removes the app's container, including all preferences, caches, favorites and layout.

## Source code

AppDrop is open source under the MIT license. You can audit every network call by reading the source — there's no obfuscation and no closed-source binary blob (except the bundled mbedTLS library, which is Apache-2.0 and whose source is also public).

- GitHub repository: https://github.com/AdrienRL1/AppDrop

## Contact

For privacy questions, open an issue on the GitHub repository.

## Changes to this policy

Material changes are announced in the release notes of new versions. This version applies to **AppDrop v3.0** and later.
