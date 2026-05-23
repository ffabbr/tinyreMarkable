# Tiny reMarkable

A macOS menu bar app for uploading PDFs to your reMarkable tablet and downloading
documents/notebooks back as PDF — including single-page exports — via the
reMarkable cloud. (Swift package / target name: `tinyreMarkable`; the shipped app
is named **Tiny reMarkable**.)

## How it works

- AppKit `NSStatusItem` + native `NSMenu` menu bar app. macOS 13+ (Apple Silicon & Intel).
- Talks to the reMarkable cloud through [`ddvk/rmapi`](https://github.com/ddvk/rmapi).
  The binary isn't bundled — on the first cloud action the app downloads the
  matching release for your Mac's architecture from ddvk/rmapi's GitHub releases
  and caches it in `~/Library/Application Support/tinyreMarkable/bin/`. This means
  rmapi updates are picked up automatically, without a new app release.
- **Auth**: on launch it reuses the `devicetoken` from the official reMarkable
  Mac app (`~/Library/Containers/com.remarkable.desktop/.../com.remarkable.desktop.plist`),
  writing it to `~/Library/Application Support/rmapi/rmapi.conf`. If the desktop
  app isn't installed, the menu shows **Sign in to reMarkable…**, which opens
  my.remarkable.com and pairs with an 8-character one-time code.
- **Download**: `rmapi get` fetches the archive; uploaded docs use the embedded
  source PDF, while pure handwritten notebooks are rendered locally
  (`rmc`: rm v6 → SVG, then SVG → PDF via headless `WKWebView`). Page rendering
  runs in parallel, and single-page exports render only the page you ask for.

## Install

Grab the latest `.dmg` from [Releases](https://github.com/ffabbr/tinyreMarkable/releases),
open it, and drag **Tiny reMarkable** to **Applications**.

The app is only ad-hoc signed (no paid Apple Developer ID), so Gatekeeper will
warn on first launch. Right-click the app → **Open**, then confirm (or System
Settings → Privacy & Security → *Open Anyway*). If macOS instead claims the app
is *"damaged and can't be opened"*, clear the download-quarantine flag once:

    xattr -dr com.apple.quarantine "/Applications/Tiny reMarkable.app"

then open it normally.

## Run from source

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
```
(rmapi is downloaded at runtime, so there's no bundled `Resources/`.)

## Notes

- Works on both Apple Silicon and Intel: the right rmapi build is fetched per-arch
  at runtime, so no `lipo`/universal binary is needed. (The app itself is built
  arm64 by `package.sh`; build for Intel separately if you need an Intel `.app`.)
- First cloud action needs an internet connection to download rmapi (one-time, cached).
- No code signing/notarization, so users must right-click → Open on first launch.
- Handwritten-notebook rendering needs Python 3.10+ (the `rmc` venv is
  auto-installed once on first notebook export).

## Packaging a release

`packaging/package.sh [version]` builds the release binary, assembles
`Tiny reMarkable.app` (with the generated `AppIcon.icns`), and produces a styled
DMG installer under the SwiftPM release bin path. `packaging/make_icon.swift`
regenerates the icon (reMarkable logo on `#f9f6f1`).
