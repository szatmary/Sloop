# Releases

**Nothing is published automatically, on purpose.**

CI (`.github/workflows/ci.yml`, the `release-build` job) builds the macOS app
in its Release configuration on every push to `main`, on a `v*` tag, and on a
manual run, and attaches the result to the workflow run as an artifact. It
creates no GitHub Release and moves no tag.

That is a deliberate step back from what this file used to describe. There were
two publish steps and neither did what it claimed:

- A rolling `nightly` pre-release, refreshed "on every push to `main`" — except
  the workflow only fired `push` on tags, so the step could never run at all.
  The `nightly` release that existed was three weeks stale.
- A `v*` tag publish that attached an **SSH-only, ad-hoc-signed** build: not
  the full variant, not signed by anything a user's Gatekeeper trusts, and on a
  collision course with `Scripts/sign-release.sh`, which does the real thing
  locally and also wants to create a release for that tag.

Both are gone. Handing someone an unsigned build with instructions to run
`xattr -cr` on it teaches them to disable the check that protects them, and it
is not a thing to automate.

## Getting a build today

From a workflow run: open the run on the Actions tab and download the
`Sloop-macOS-unsigned` artifact. It is unsigned and for your own machines only.

Locally, and properly: `Scripts/sign-release.sh` archives, signs with a
Developer ID, notarizes and staples. See [`SIGNING.md`](SIGNING.md) — note that
notarization has never been run end to end, and the prerequisites it needs are
in [`LAUNCH.md`](LAUNCH.md) §1 and §4.

## What has to exist before this can publish again

- **Developer ID signing in CI** — the certificate and profile as repository
  secrets, and `sign-release.sh` proven end to end locally first. Both App IDs,
  the app group and both keychain groups need registering in the developer
  portal before any of it will build.
- **Notarization** — the `sloop-notary` credential, and one successful
  `notarytool` submission. Until then a published build is one a user cannot
  open without being told to bypass Gatekeeper.
- **iOS** — there is no archive or export path at all yet. It needs the privacy
  manifests, export compliance in the plist, and an iOS distribution
  certificate. See [`LAUNCH.md`](LAUNCH.md).

When those land, the release job already builds the right thing from
`project.tailscale.yml` — SSH, Mosh, Tailscale and the File Provider extension
together — so publishing becomes a step to add rather than a pipeline to
rewrite.
