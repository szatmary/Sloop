# Licensing — decide before shipping

Sloop is meant to be free (no cost). That's a pricing choice; the *license* is a
separate, real decision because two dependencies we want are copyleft.

## The dependencies

| Component | License | Notes |
| --- | --- | --- |
| SwiftTerm | MIT | No obligations beyond attribution. Fine. |
| libssh2 | BSD-style | Permissive. Fine. |
| **Mosh** | **GPLv3** | Copyleft. This is the one to think about. |
| Blink Shell | GPLv3 (historically) | We are *not* copying its code — building fresh — so its license doesn't bind us. Don't paste Blink source in. |

## The GPL ⇄ App Store tension

The App Store's terms (usage rules, DRM) have long been considered incompatible
with GPLv2/GPLv3 as applied to third-party-licensed code, because they add
restrictions the GPL forbids. The practical outcomes people use:

1. **You are the sole copyright holder / distributor.** If Sloop's own code is
   yours and you distribute it, you can license *your* code however you like.
   The catch is the *GPL'd Mosh code you bundle* — you'd be redistributing GPL
   binaries under App Store terms, which is the disputed part.
2. **Keep Mosh out of the shipped binary.** Ship SSH-only on the App Store; make
   Mosh an optional component the user builds/sideloads, or connect to a
   user-provided `mosh-server` without bundling the GPL client. Sidesteps the
   conflict.
3. **Reimplement the SSP transport cleanly** under a license you control, using
   the Mosh *protocol* (not its code). More work; removes the GPL dependency.
4. **Dual-license / get an exception.** Only the copyright holders of Mosh could
   grant this — unlikely.

## Recommendation

Ship **M1 (SSH-only)** under a permissive license for your own code (MIT/BSD)
with no copyleft dependencies — clean App Store story. Treat **Mosh (M3)** as a
gated decision: pick option 2 or 3 above before bundling it, rather than
discovering the conflict at review time.

This file is a placeholder for that decision. Add the actual `LICENSE` once the
approach is chosen.
