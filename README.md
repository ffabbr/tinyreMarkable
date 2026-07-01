# Tiny reMarkable

A macOS menu bar app for uploading PDFs (and images) to your reMarkable tablet
and downloading documents back as PDF — whole file or single pages — via the
reMarkable cloud. Handwriting you added on top of an uploaded PDF is included in
the export.

macOS 13+, Apple Silicon & Intel. (Swift package / target: `tinyreMarkable`; the
shipped app is **Tiny reMarkable**.)

## How it works

- AppKit `NSStatusItem` + native `NSMenu`. Cloud access goes through
  [`ddvk/rmapi`](https://github.com/ddvk/rmapi), which isn't bundled — on the
  first cloud action the app downloads the release matching your Mac's
  architecture and caches it in `~/Library/Application Support/tinyreMarkable/`,
  so rmapi updates are picked up without a new app release.
- **Auth**: reuses the `devicetoken` from the official reMarkable desktop app if
  it's installed. Otherwise the menu offers **Sign in to reMarkable…**, which
  opens my.remarkable.com and pairs with an 8-character one-time code.
- **Download**: a plain uploaded PDF is exported as-is; a PDF you wrote on has
  its ink rendered locally and composited onto each page; a pure handwritten
  notebook is rendered page by page. Rendering runs in parallel, and single-page
  exports only render the page you ask for.

## Install

Grab the latest `.dmg` from
[Releases](https://github.com/ffabbr/tinyreMarkable/releases) and drag
**Tiny reMarkable** to **Applications**.

The app is only ad-hoc signed (no paid Apple Developer ID), so Gatekeeper warns
on first launch. Right-click the app → **Open**, then confirm. If macOS instead
says the app is *"damaged"*, clear the quarantine flag once:

    xattr -dr com.apple.quarantine "/Applications/Tiny reMarkable.app"

## Run from source

    swift run

Then click the reMarkable logo in the menu bar:

- **Upload PDF to …** (or drag a PDF/image onto the menu bar icon).
- Per document: **Save as PDF (all pages)**, the **first / last /
  second-to-last** page, or **Other ▸** to pick one of the first 50 pages.
- A busy bar shows while an operation runs; the menu offers **Cancel**.

## Notes

- The right rmapi build is fetched per-arch at runtime, so no universal binary
  is needed. The first cloud action needs an internet connection (one-time).
- Rendering handwriting needs Python 3.10+; the `rmc` virtualenv is
  auto-installed once, on the first export that contains ink.
- **Packaging**: `packaging/package.sh [version]` builds `Tiny reMarkable.app`,
  ad-hoc signs it, and produces a styled DMG. `packaging/make_icon.swift`
  regenerates the icon.

## License & credits

Tiny reMarkable is MIT-licensed (see [`LICENSE`](LICENSE)). It relies on
[`ddvk/rmapi`](https://github.com/ddvk/rmapi) (AGPL-3.0) and
[`rmc`](https://github.com/ricklupton/rmc) (MIT), both run as separate programs
fetched at runtime — see [`NOTICE.md`](NOTICE.md). Unofficial and not affiliated
with reMarkable AS.
