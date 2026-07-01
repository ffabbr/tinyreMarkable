# Third-party components

Tiny reMarkable itself is MIT-licensed (see `LICENSE`). It does not bundle or
statically link any third-party code; it invokes the tools below as separate
programs, fetched at runtime. Each remains under its own license.

- **[ddvk/rmapi](https://github.com/ddvk/rmapi)** — reMarkable cloud CLI.
  Licensed **AGPL-3.0**. Downloaded on first use from the project's GitHub
  releases and run as a separate process; not modified or redistributed here.

- **[rmc](https://github.com/ricklupton/rmc)** (with
  [rmscene](https://github.com/ricklupton/rmscene)) — reMarkable v6 `.rm` → SVG
  rendering. `rmc` is licensed **MIT**. Installed on first use into a local
  Python virtual environment via `pip` and invoked as a separate process.

These projects are not affiliated with or endorsed by this app. "reMarkable" is
a trademark of reMarkable AS; this is an unofficial, independent tool.
