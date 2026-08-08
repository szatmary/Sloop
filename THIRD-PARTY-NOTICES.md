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
