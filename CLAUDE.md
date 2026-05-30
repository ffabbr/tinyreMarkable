# tinyreMarkable

A macOS menu bar app to upload PDFs to a reMarkable tablet and download documents/notebooks as PDF (including page ranges), via the reMarkable cloud. Handwritten annotations made on top of an uploaded PDF are composited back onto the exported PDF.

## Stack
- Swift Package (`swift build` / `swift run`), AppKit `NSStatusItem` + native `NSMenu`. macOS 13+, arm64 + Intel.
- Cloud access via [`ddvk/rmapi`](https://github.com/ddvk/rmapi) (NOT the unmaintained juruen fork). The binary is **not bundled** — it's auto-downloaded on first use from ddvk/rmapi's GitHub releases (`releases/latest/download/...`), so new rmapi versions are picked up without shipping an app update.
- Handwriting rendering: a one-time auto-installed Python venv with `rmc` (rm v6 → SVG), then SVG → PDF via headless `WKWebView`. Used both for pure notebooks and for the ink layer composited onto annotated PDFs.

## Layout
```
Sources/tinyreMarkable/
  main.swift             NSApp bootstrap
  AppDelegate.swift      Status item, NSMenu, busy indicator, all actions
  RMClient.swift         rmapi process wrapper, auth bootstrap, error mapping
  RMArchive.swift        Parses the unzipped rmapi archive (.content, pages, embedded PDF, orientation, hasAnnotations)
  NotebookRenderer.swift rmc venv setup + .rm → SVG → PDF pipeline; annotation compositing onto source PDFs
  PDFSlicer.swift        PDFKit page-range extraction
  Models.swift           RMItem
```
(No `Resources/` — rmapi is downloaded at runtime, not bundled.)

## Key facts
- **rmapi binary**: `RMClient.ensureBinary()` lazily downloads the per-arch release zip (`rmapi-macos-arm64.zip` / `rmapi-macos-intel.zip`, chosen via `uname`) into `~/Library/Application Support/tinyreMarkable/bin/rmapi` on the first cloud command, unzips it, and `chmod 0755`s it. Concurrent callers share one in-flight `installTask`. URLSession downloads carry no `com.apple.quarantine` flag, so the binary runs even though the app is unsigned. Failures surface as `RMError.binaryDownloadFailed`. Tracking `latest` means a future rmapi CLI change could break parsing — pin a version in `downloadURL` if that happens.
- **Auth**: reuses the official desktop app's `devicetoken` (from `com.remarkable.desktop` sandbox plist) → written to `~/Library/Application Support/rmapi/rmapi.conf`. If the desktop app isn't installed, the menu offers a one-time-code sign-in (`RMClient.register`) that pipes the 8-char code from my.remarkable.com to rmapi (watchdog-guarded — rmapi loops forever on a bad code).
- **Download uses `rmapi get`, not `geta`** — `geta` (cloud-side annotated render) is unreliable and fails outright on some docs. We unzip the archive and `RMClient.prepare()` classifies it into one of three `PreparedDocument.Source` cases:
  - `.embeddedPDF` — plain uploaded PDF, no ink: the embedded `<uuid>.pdf` is exported as-is (lossless, fast; single-page exports slice with `PDFSlicer`).
  - `.annotatedPDF` — uploaded PDF *with* handwriting (`RMArchive.hasAnnotations`, i.e. at least one page has a `.rm` stroke file): `NotebookRenderer.compositeAnnotatedPDF` draws each PDF page, then overlays that page's rmc-rendered ink.
  - `.notebook` — pure handwritten notebook: rendered page-by-page (parallelized).
  Single-page exports get the page count cheaply from `.content` and render/composite only the requested page.
- **Annotation compositing geometry** (`NotebookRenderer.annotationTransform`): rmc emits v6 ink already upright (landscape ink is **not** rotated) in PDF points, x centered at 0, y from page top. The ink maps onto the page at **1:1 scale, no rotation**; only the horizontal anchor depends on `.content` `orientation` — portrait shifts x by `canvasW/2`, landscape by `canvasH` (canvasW = 1404·72/226, canvasH = 1872·72/226). y passes straight through. The white-backed overlay is drawn with `.multiply` blend (so white vanishes, ink shows over the PDF) via `CGPDFDocument`/`drawPDFPage`. This model was reverse-engineered empirically; `.content` zoom fields and fit-to-width/height theories did **not** match real output. No off-the-shelf tool fits — `remarks` rejects v6 `.rm`, `rmrl` is v5-only.
- rmapi outputs `.zip` for plain PDFs and `.rmdoc` (also a zip) for notebooks and annotated PDFs.
- rmapi errors are mapped to friendly `RMError` cases (offline, auth expired, not found, etc.) in `RMClient.swift` by matching stderr substrings.

## Notes
- The app build is arm64, but rmapi is fetched per-arch at runtime, so an Intel Mac gets the Intel rmapi automatically — no `lipo` needed.
- Dev workflow (`swift run`) uses no code signing. Packaged builds are ad-hoc signed (identity `-`) in `package.sh` so Gatekeeper offers the normal "Open Anyway" flow rather than the "app is damaged" dead-end that unsigned + quarantined bundles trigger. Real Developer ID signing would still need an Xcode project for entitlements.
- **Packaging**: `packaging/package.sh [version]` builds `Tiny reMarkable.app` (display name; internal target stays `tinyreMarkable`), ad-hoc signs it, and produces a styled DMG. There are no bundled resources to copy (rmapi is downloaded on first use). `packaging/make_icon.swift` renders the icon.
