# Changelog

Older release notes are also available on the [GitHub Releases](https://github.com/AdrienRL1/AppDrop/releases) page.

## AppDrop v2.0 — Categories, "Works today", feedback & a self-updating catalog

The biggest AppDrop update yet. A brand-new home screen, a curated list of apps that still work today, an in-app feedback channel, a catalog that keeps itself up to date, an 8th language, and a lot of polish.

### Install / update

Add the source on your jailbroken device (Cydia → **Sources → Edit → Add**):

```
https://adrienrl1.github.io/cydia/
```

Then **AdrienRL → AppDrop → Install** (or **Upgrade** if you already have it). Cydia pulls AppSync Unified and IPA Installer Console for you.

### Major new features

- **Browse by category** — the home screen is now a clean category grid (Games, Utilities, Entertainment, …) with live app counts, plus quick rows for "All apps" and "Works today". Tap a category to drill in.
- **"Works today"** — a section for apps confirmed to still install and run on old iOS, with one-tap install and **automatic update detection** ("Update to vX" when a newer build is available). For now it holds a single app — the section is there to grow as more get added over time.
- **Self-updating catalog** — the catalog is downloaded on first launch and then **refreshed automatically** whenever new apps are added. You never have to reinstall the app just to get new content. Startup stays instant (the cached catalog loads first, the check runs in the background).
- **In-app feedback** — found a bug or have an idea? The **Feedback** button (top-left of the home screen) lets you write a message and attach screenshots, sent straight to the project — no account needed.
- **Localized app descriptions** — thousands of apps now have rich descriptions, written in all 8 languages.
- **8th language: Turkish** — joins English, French, Spanish, German, Portuguese (BR), Japanese, and Simplified Chinese. The app auto-detects your device language. Turkish translation contributed by **Yusubera** on Reddit — thank you!
- **DNS-over-HTTPS fallback** — if your ISP blocks archive.org at the DNS level, AppDrop now resolves it over HTTPS so installs keep working.
- **Support AppDrop** — an optional "Support AppDrop" button (top-right of the home screen) with the developer's PayPal, for anyone who wants to chip in.

### Smarter & device-aware

- **Compatibility verdict** — every app's detail screen now shows a clear banner, computed from the app's real minimum iOS and device type (no guessing): green "Compatible with your <device>", or red "Requires iOS X — your device runs Y" / "Made for iPad — won't run here".
- **Auto-picks a version you can run** — if an app's newest build needs a newer iOS than your device, AppDrop automatically selects the latest version your device *can* run (with a note) instead of letting you install something that won't launch. You can still pick any specific build from the **Versions** list, which now greys out and flags the builds your device can't run.
- **Device-aware catalog** — category lists and their counts only include apps that actually run on your device, so iOS 11+-only apps no longer clutter the browse.

### Downloads & installs

- **Configurable simultaneous downloads** — new setting for the max number of apps downloading at once (1–8, default 2).
- **Clearer install list** — a live "**N downloading · M waiting**" counter at the top, **active downloads sorted to the top** and waiting ones below, and a clear "Waiting…" state so a queued app never looks stuck.

### Performance & polish

- **Much smoother scrolling** — app icons are decoded off the main thread and cached on disk (an icon you've seen once loads instantly forever, even after relaunch), so the catalog and search grids scroll fluidly even on an iPad 4 / A6X.
- **Refreshed grid** — cleaner rounded app tiles, denser iPad layouts (up to 12 per row), and a live "apps per row" control in Settings.
- **Rotation fix** — the number of apps per row is now consistent across every row after rotating the screen.
- **More reliable AI search** — LLM requests retry automatically (with a fallback model) instead of failing on the first network hiccup.
- **Smaller download** — the app package is ~1.3 MB (the catalog is fetched at runtime instead of being bundled).
- Assorted layout, rotation, and translation fixes.

### Compatibility

- **iOS 5.0 – 10.x** (armv7 / 32-bit). Tested on iPad 1 (iOS 5.1.1), iPhone 5 (iOS 6.1.4), iPad 4 (iOS 6.1.3), and iPad mini 2 (iOS 10.3.3).
- iOS 11+ is not supported (Apple dropped 32-bit apps).
