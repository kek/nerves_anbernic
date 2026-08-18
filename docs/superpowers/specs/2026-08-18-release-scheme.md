# Release and tag scheme

**Status:** planned. Not to be executed until the display fix (`v0.7.0`) and the
Nerves-toolchain switch are validated on hardware.

## What is wrong now

`VERSION` has said `0.1.0` across seven tags. The tags move; the version does
not; and the tooling reads only the version. So there are two numbering schemes
and neither identifies a build — the only thing that does is the artifact
checksum.

This was not designed. The publish step was gated on `refs/tags/v*`, so
version-shaped tags got invented to make builds publish. When it later turned
out that `:github_releases` derives the release it queries from the project
version rather than from the tag, the mismatch was explained away rather than
fixed, and the explanation was written into `ci.yml` and a commit message as
though it were a principle: *"the tag is a build trigger and a label, and the
version is the address."* That sentence is a rationalisation, and encoding it
made the incoherence permanent instead of visible.

It also lost something. Every artifact now lands on release `v0.1.0`, so nothing
maps a tag to the asset it produced except CI logs, and that page accumulates
560 MB tarballs distinguished only by checksum.

## The scheme

One version, one tag, one release, one artifact.

- **`VERSION` is bumped in the commit that is about to be tagged.** Never
  separately, never skipped.
- **The tag is `v$(cat VERSION)`.** They are the same string or the build fails.
- **The release is that tag**, and the artifact is published to it. `deps.get`
  queries `v$VERSION`, which is now also the tag, so the address and the label
  agree by construction.
- **Numbering restarts at `v0.1.0`** with the first release cut under this
  scheme, which is the current `VERSION` value — no bump needed for the first
  one.
- After that, `0.x` semver: minor for BSP changes, patch for fixes. Breaking
  changes are expected while the major is 0.

The objection that bumping `VERSION` "costs a rebuild" because it is in
`checksum_files()` is empty. `VERSION` is only bumped when cutting a release,
and cutting a release means building anyway. The bump is never a separate event
needing its own build.

## Migration

Ordered, because two of these steps race with anything in flight.

1. **Validate first.** `v0.7.0` on hardware: panel timing, and that the
   Nerves-toolchain switch produced a working image. Nothing below happens until
   that is settled — the whole point of the current tags is to get that answer.

2. **Confirm the local cache holds the validated artifact.** `~/.nerves/dl`
   currently has 40 of them, and deleting releases does not touch it. This is
   what covers the gap in step 4.

3. **Delete every release and every tag.**

   ```
   for t in v0.1.0 v0.2.0 v0.3.0 v0.4.0 v0.5.0 v0.6.0 v0.7.0; do
     gh release delete "$t" -R kek/nerves_system_rg40xxv --yes --cleanup-tag
   done
   git tag -d v0.1.0 ... && git push origin --delete v0.1.0 ...
   ```

   Releases currently carrying assets: `v0.1.0` (`6A79755`), `v0.2.0`
   (`A58E483`), `v0.3.0` (`D2E00D8`), `v0.4.0` (`A0F1E07`), plus whatever
   `v0.5.0`–`v0.7.0` attach before this runs. `--cleanup-tag` removes the remote
   tag with the release; local tags need `git tag -d` as well.

   Nothing depends on these. mayonnaios resolves by checksum against whatever is
   published, and its working copy is what decides which checksum it wants.

4. **Accept a one-build window with nothing published.** Between the deletion
   and the first new build completing, `mix deps.get` on a clean machine has
   nowhere to resolve from. On this machine `~/.nerves/dl` covers it. Do not do
   this immediately before needing to flash something.

5. **Land the enforcement changes** (below), leave `VERSION` at `0.1.0`, tag
   `v0.1.0`, push. The build publishes to a fresh release `v0.1.0` whose tag,
   version, and asset all agree.

## What changes in the code

`.github/workflows/ci.yml`:

- The `destination` step already computes `v$(cat VERSION)`. Keep it, and add an
  assertion that it equals `github.ref_name` on tag pushes. Failing loudly on
  divergence is what makes the scheme self-enforcing rather than a convention
  someone remembers. This is the whole fix; everything else is tidying.
- Drop `make_latest: false`. It exists because artifacts were accumulating on
  one release. With one release per version, the newest genuinely is the latest.
- The comment block explaining that "the tag is a build trigger and the version
  is the address" is now false and must go. So does the paragraph in the
  `destination` step describing tags v0.2.0/v0.3.0 publishing to pages nothing
  reads — keep the history in this document instead.

`CHANGELOG.md` gets an entry per release. It is in `prose_files()`, not
`checksum_files()`, so writing it is free and can happen after the fact if
needed.

Consider letting the release body come from the tag annotation, since tags are
now 1:1 with releases and the annotations are already written as release notes.

## Follow-up found while writing this

The `scope` step skips the build only when a push touches solely `.github/`.
But the real question is whether anything in `checksum_files()` changed — a
docs-only push currently triggers a three-and-a-half-hour build that cannot
produce a different artifact. Widening the gate to "nothing in
`checksum_files()` changed" would make `docs/` genuinely free, which is what
splitting the checksum list was for in the first place.

## How to tell it worked

- `gh release list` shows one release per version, newest latest.
- Each release has exactly one asset, and its filename embeds the same version
  as the tag: `nerves_system_rg40xxv-portable-0.1.0-<checksum>.tar.gz` on
  `v0.1.0`.
- A tag whose name does not match `VERSION` fails CI in the cheap job.
- `mix deps.get` in mayonnaios resolves without the `~/.nerves/dl` shuffle.
