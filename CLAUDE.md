# tinyreMarkable

A macOS menu bar app to upload PDFs to a reMarkable tablet and download documents/notebooks as PDF (including page ranges), via the reMarkable cloud.

## Stack
- Swift Package (`swift build` / `swift run`), AppKit `NSStatusItem` + native `NSMenu`. macOS 13+, arm64 + Intel.
- Cloud access via [`ddvk/rmapi`](https://github.com/ddvk/rmapi) (NOT the unmaintained juruen fork). The binary is **not bundled** — it's auto-downloaded on first use from ddvk/rmapi's GitHub releases (`releases/latest/download/...`), so new rmapi versions are picked up without shipping an app update.
- Handwritten-notebook rendering: a one-time auto-installed Python venv with `rmc` (rm v6 → SVG), then SVG → PDF via headless `WKWebView`.

## Layout
```
Sources/tinyreMarkable/
  main.swift             NSApp bootstrap
  AppDelegate.swift      Status item, NSMenu, busy indicator, all actions
  RMClient.swift         rmapi process wrapper, auth bootstrap, error mapping
  RMArchive.swift        Parses the unzipped rmapi archive (.content, pages, embedded PDF)
  NotebookRenderer.swift rmc venv setup + .rm → SVG → PDF pipeline
  PDFSlicer.swift        PDFKit page-range extraction
  Models.swift           RMItem
```
(No `Resources/` — rmapi is downloaded at runtime, not bundled.)

## Key facts
- **rmapi binary**: `RMClient.ensureBinary()` lazily downloads the per-arch release zip (`rmapi-macos-arm64.zip` / `rmapi-macos-intel.zip`, chosen via `uname`) into `~/Library/Application Support/tinyreMarkable/bin/rmapi` on the first cloud command, unzips it, and `chmod 0755`s it. Concurrent callers share one in-flight `installTask`. URLSession downloads carry no `com.apple.quarantine` flag, so the binary runs even though the app is unsigned. Failures surface as `RMError.binaryDownloadFailed`. Tracking `latest` means a future rmapi CLI change could break parsing — pin a version in `downloadURL` if that happens.
- **Auth**: reuses the official desktop app's `devicetoken` (from `com.remarkable.desktop` sandbox plist) → written to `~/Library/Application Support/rmapi/rmapi.conf`. If the desktop app isn't installed, the menu offers a one-time-code sign-in (`RMClient.register`) that pipes the 8-char code from my.remarkable.com to rmapi (watchdog-guarded — rmapi loops forever on a bad code).
- **Download uses `rmapi get`, not `geta`** — `geta` is unreliable. We unzip the archive, use the embedded `<uuid>.pdf` for uploaded docs, or render `.rm` files for pure notebooks. Single-page exports get the page count cheaply from `.content` and render only the requested page; notebook page rendering is parallelized.
- rmapi outputs `.zip` for PDFs and `.rmdoc` (also a zip) for notebooks.
- rmapi errors are mapped to friendly `RMError` cases (offline, auth expired, not found, etc.) in `RMClient.swift`.

## Notes
- The app build is arm64, but rmapi is fetched per-arch at runtime, so an Intel Mac gets the Intel rmapi automatically — no `lipo` needed.
- No code signing — runs via `swift run`. A real `.app` would need an Xcode project for entitlements/signing.
- **Packaging**: `packaging/package.sh [version]` builds `Tiny reMarkable.app` (display name; internal target stays `tinyreMarkable`) and a styled DMG. There are no bundled resources to copy anymore (rmapi is downloaded on first use). `packaging/make_icon.swift` renders the icon.
