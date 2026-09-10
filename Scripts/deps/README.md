# `Scripts/deps` — what Sloop changes about its native dependencies

Every `Vendor/*.xcframework` is built from upstream source by a script in
`Scripts/`. Some of that source needs changing first. This directory holds those
changes, split by what they actually are:

```
Scripts/deps/<dep>/patches/*.patch   edits to upstream source
Scripts/deps/<dep>/files/*           files Sloop owns outright
```

`Scripts/lib/vendor.sh` applies them — `apply_patches`, `install_file`,
`append_file` — and pins `IOS_CMAKE_TAG` for every script that clones
`ios-cmake`.

## Why the split matters

These were the same thing before: `sed -i` calls and heredocs inside the build
scripts. Two problems came out of that.

A heredoc is not reviewable. A diff that changes one line inside a 14-line
heredoc tells you nothing about what the resulting file looks like, and the
resulting file gets no syntax highlighting, no compiler, and no `git blame` of
its own.

Worse, a file that only exists in a heredoc has no copy in the repository. The
libssh2 module map was generated straight into `Vendor/libssh2.xcframework`,
which `.gitignore` excludes — so when it turned out to be missing
`libssh2_sftp.h` and every `libssh2_sftp_*` symbol was invisible to Swift, there
was nothing checked in to correct. It had to be fixed in the generator and then
by hand in three built slices.

## Patches

Real unified diffs, applied with `git apply` in filename order. Each carries its
own explanation above the diff — what breaks without it, and how that was found.

`git apply` verifies context and names the file and hunk it could not place, so
there is no follow-up `grep` confirming the edit landed. The `sed … || echo
"upstream moved"` pattern this replaced could only report *that* something was
wrong, never where.

Re-running a build against an existing checkout is normal during development, so
an already-applied patch is skipped rather than treated as a failure. A patch
that neither applies nor reverses is a real error and stops the build.

**When upstream moves,** re-cut the patch against the newly pinned tag. Do not
edit the source in place — that is what this directory exists to prevent.

## Files

Copied into the build or output tree verbatim. Not patches, because nothing of
upstream's version survives (mosh's `terminaldisplayinit.cc`) or because
upstream has no version at all (the libssh2 module map).

`append_file` covers the one case where upstream's contents must survive and
Sloop adds to the end — libtailscale's `tailscale.h`, which gains a single
exported declaration.

## What is deliberately not here

mosh's `config.h` macro disabling stays a `sed` loop in `build-mosh.sh`. It
edits *generated* output whose content differs per slice, so no patch file could
match it, and the list of macros is data — a loop over their names says what is
happening more clearly than a diff would.
