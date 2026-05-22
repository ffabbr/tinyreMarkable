# tinyreMarkable

A macOS menu bar app for uploading PDFs to your reMarkable tablet and downloading
documents/notebooks back as PDF — including single-page exports — via the
reMarkable cloud.

## How it works

- AppKit `NSStatusItem` + native `NSMenu` menu bar app. macOS 13+, arm64.
- Talks to the reMarkable cloud through a bundled
  [`ddvk/rmapi`](https://github.com/ddvk/rmapi) binary
  (`Sources/tinyreMarkable/Resources/rmapi`).
- **Auth**: on launch it reuses the `devicetoken` from the official reMarkable
  Mac app (`~/Library/Containers/com.remarkable.desktop/.../com.remarkable.desktop.plist`),
  writing it to `~/Library/Application Support/rmapi/rmapi.conf`. If the desktop
  app isn't installed, the menu shows **Sign in to reMarkable…**, which opens
  my.remarkable.com and pairs with an 8-character one-time code.
- **Download**: `rmapi get` fetches the archive; uploaded docs use the embedded
  source PDF, while pure handwritten notebooks are rendered locally
  (`rmc`: rm v6 → SVG, then SVG → PDF via headless `WKWebView`). Page rendering
  runs in parallel, and single-page exports render only the page you ask for.

## Run

    swift run

Look for the reMarkable logo in the menu bar and click it.

- **Upload PDF to …** — pick a PDF; it's uploaded to that folder.
- Per document: **Save as PDF (all pages)**, or export the **first / last /
  second-to-last** page, or **Other ▸** to pick any single page.
- While an operation is running, a busy bar shows in the menu bar and the menu
  offers **Cancel**.

## Files

```
Package.swift
Sources/tinyreMarkable/
  main.swift             NSApp bootstrap
  AppDelegate.swift      status item, NSMenu, busy indicator, all actions
  RMClient.swift         rmapi process wrapper, auth + OTC pairing, error mapping
  RMArchive.swift        parses the unzipped rmapi archive
  NotebookRenderer.swift rmc venv setup + .rm → SVG → PDF pipeline (parallel)
  PDFSlicer.swift        PDFKit page extraction
  Models.swift           RMItem
  Resources/rmapi        bundled ddvk/rmapi binary (arm64)
```

## Notes

- arm64 only. For Intel/universal, `lipo -create` the macos-arm64 and
  macos-intel rmapi releases into `Resources/rmapi`.
- No code signing — runs via `swift run`. A real `.app` would need an Xcode
  project for entitlements/signing.
- Handwritten-notebook rendering needs Python 3.10+ (the `rmc` venv is
  auto-installed once on first notebook export).
