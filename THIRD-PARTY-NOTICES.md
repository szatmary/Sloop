# Third-party notices

Sloop is licensed under the GNU General Public License v3.0 (see `LICENSE`). It
builds on the following third-party components. Their licenses are reproduced or
linked below; each remains under its own terms.

| Component | License | Bundled in the app? | Role |
| --- | --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | MIT | Yes (SwiftPM) | Terminal view + emulator |
| [libssh2](https://www.libssh2.org) | BSD-3-Clause | Yes (`Vendor/libssh2.xcframework`) | SSH transport |
| [Mosh](https://mosh.org) | **GPL-3.0** | Yes (`Vendor/mosh.xcframework`) | UDP/SSP mobile-shell transport |
| [Protocol Buffers](https://github.com/protocolbuffers/protobuf) | BSD-3-Clause | Yes (merged into `mosh.xcframework`) | Mosh's wire format |
| zlib (`libz`) | zlib | No — Apple SDK system library | Mosh payload compression |
| [ios-cmake](https://github.com/leetal/ios-cmake) | BSD-3-Clause | No — build tooling only | Cross-compile toolchain |

## Why Sloop is GPL-3.0

Mosh is GPL-3.0 (copyleft), and the app bundles it, so the combined work is
distributed under GPL-3.0. This is a deliberate, viable choice — see
`Docs/LICENSING.md` for the full reasoning, including how GPL-3.0 and App Store
distribution coexist when the corresponding source stays public (this repo).

## Obligations we meet

- **Corresponding source**: this repository is public; every release links back
  to the exact source it was built from.
- **License texts**: `LICENSE` carries the full GPL-3.0. The permissive licenses
  (MIT, BSD-3-Clause, zlib) require attribution, satisfied by this file and the
  upstream links above.
- **No proprietary relinking**: Sloop ships as GPL-3.0; it does not relink
  Mosh into a proprietary binary.

If a formal per-dependency license dump is wanted for an App Store submission,
generate one from the resolved SwiftPM graph plus the vendored xcframeworks'
upstream `COPYING`/`LICENSE` files at release time.

## How Sloop's own code was written

Most of Sloop's own source — `Sources/SloopKit`, `App/Sloop`, the build scripts,
and these docs — was written with LLM assistance (Anthropic's Claude) under human
direction and review. Architecture, design decisions, and review are the
author's; a large share of the typing is not.

This covers Sloop's own code only. The third-party components listed above are
separate upstream projects, vendored or fetched unmodified; how they were
written is theirs to state, not ours.

This is a statement of provenance, not a copyright disclaimer. Sloop's own code
is copyrighted and licensed under GPL-3.0 along with the rest of the app, per
`LICENSE`.

## The name and icon are reserved

GPL-3.0 covers **code.** It grants no rights in the name **Sloop** or the app
icon (`App/Sloop/AppIcon.svg` and
`App/Sloop/Assets.xcassets/AppIcon.appiconset/`), which are reserved. GPL-3.0
§7(e) expressly permits "declining to grant rights under trademark law for use
of some trade names, trademarks, or service marks."

So: exercise your GPL rights in the code, but ship any fork under its own name
and icon, not these.
