# tinyreMarkable

A macOS menu bar app to upload PDFs to a reMarkable tablet and download documents/notebooks as PDF (including page ranges), via the reMarkable cloud.

## Stack
- Swift Package (`swift build` / `swift run`), AppKit `NSStatusItem` + native `NSMenu`. macOS 13+, arm64.
- Cloud access via a bundled [`ddvk/rmapi`](https://github.com/ddvk/rmapi) binary (NOT the unmaintained juruen fork).
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
  Resources/rmapi        bundled ddvk/rmapi binary (Bundle.module)
```

## Key facts
- **Auth**: reuses the official desktop app's `devicetoken` (from `com.remarkable.desktop` sandbox plist) → written to `~/Library/Application Support/rmapi/rmapi.conf`. If the desktop app isn't installed, the menu offers a one-time-code sign-in (`RMClient.register`) that pipes the 8-char code from my.remarkable.com to rmapi (watchdog-guarded — rmapi loops forever on a bad code).
- **Download uses `rmapi get`, not `geta`** — `geta` is unreliable. We unzip the archive, use the embedded `<uuid>.pdf` for uploaded docs, or render `.rm` files for pure notebooks. Single-page exports get the page count cheaply from `.content` and render only the requested page; notebook page rendering is parallelized.
- rmapi outputs `.zip` for PDFs and `.rmdoc` (also a zip) for notebooks.
- rmapi errors are mapped to friendly `RMError` cases (offline, auth expired, not found, etc.) in `RMClient.swift`.

## Notes
- arm64 only; for Intel/universal, `lipo` together both macos releases into `Resources/rmapi`.
- No code signing — runs via `swift run`. A real `.app` would need an Xcode project for entitlements/signing.
