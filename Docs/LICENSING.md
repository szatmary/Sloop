# Licensing — decide before shipping

Sloop is meant to be free (no cost). That's a pricing choice; the *license* is a
separate, real decision because one dependency we want is copyleft.

## The dependencies

| Component | License | Notes |
| --- | --- | --- |
| SwiftTerm | MIT | No obligations beyond attribution. Fine. |
| libssh2 | BSD-style | Permissive. Fine. |
| **Mosh** | **GPLv3** | Copyleft. This is the one to think about. |

Sloop's own code is written fresh — no third-party GPL source is pasted in, so
only the code we actually bundle (mosh) carries a copyleft obligation.

## The GPL ⇄ App Store tension

The App Store's terms (usage rules, DRM) are often called incompatible with the
GPL because they add restrictions the GPL forbids. But that tension is narrower
than it looks — GPLv3 apps, including terminals that bundle mosh, have shipped on
the App Store for years. Why it works:

- **The GPL binds licensees, not the author.** As the copyright holder of
  Sloop's own code, you are not your own licensee — you may distribute your work
  through the App Store *and* publish it under GPLv3. The GPL constrains people
  who receive it from you, not you.
- **Corresponding source satisfies the GPL.** Keep the full app source public
  (this repo) so every App Store user can get the corresponding source. That's
  the GPL's core obligation, and it's met by simply being open.
- **Third-party GPL code is the only real risk.** The VLC-style takedowns
  happened when a *contributor* who held copyright objected to App Store terms.
  For Sloop that means **mosh** (GPLv3, held by its authors) — the theoretical
  right to object is theirs, not ours.

So the "sidestep mosh" advice from before is *not* required. Shipping our own
GPLv3 app with mosh bundled is viable and is the recommended path.

## Recommendation

1. License **Sloop's own code GPLv3** and keep this repository public, providing
   corresponding source for every release.
2. Bundle **mosh** (M3) and libssh2, shipping their source/offer alongside.
   libssh2 is BSD (no issue); mosh is GPLv3 and provided as corresponding
   source.
3. Add a proper `LICENSE` (GPL-3.0) and a `NOTICE`/`third-party-licenses`
   listing SwiftTerm (MIT), libssh2 (BSD), and mosh (GPLv3).

Residual risk: a mosh copyright holder could object to App Store distribution.
It's low — GPLv3 terminals bundling mosh already ship there — but it is theirs to
raise. If you'd rather carry zero copyleft risk, the fallback is still M2-era
SSH-only under a permissive license — but that's a choice, not a necessity.

Action item: add `LICENSE` (GPL-3.0) and a third-party notices file before the
first App Store submission.
