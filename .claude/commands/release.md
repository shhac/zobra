---
description: Cut a zobra release — bump version, update changelog, tag, push. Optionally takes the new version (e.g. `/release 0.2.0`); inferred from the current zon version if omitted.
---

# /release — cut a zobra release

zobra is a Zig source library. A release is a git tag + a GitHub Release page; no binaries are built or uploaded. Consumers fetch via `zig fetch --save https://github.com/shhac/zobra/archive/refs/tags/vX.Y.Z.tar.gz`.

The GitHub workflow at `.github/workflows/release.yml` runs on every `v*` tag push: it verifies semver / `build.zig.zon` version match / format / tests / E2E, extracts release notes from `CHANGELOG.md`, and creates the Release page. **You don't run the workflow manually — pushing the tag triggers it.**

This command performs the local-side work to make a tag-and-push safe.

## Prerequisites checklist

Before doing any of the steps below, verify:

- [ ] You're on `main`, working tree clean (`git status`).
- [ ] `git pull --rebase` is clean — you have the latest origin/main.
- [ ] Tests + E2E + fmt all pass locally:
  - `zig build test --summary all`
  - `zig build test-e2e --summary all`
  - `zig fmt --check src test build.zig examples`
- [ ] The CHANGELOG entry for the new version is written under a `## [X.Y.Z] - YYYY-MM-DD` header (the workflow's release-notes extractor depends on this exact shape).
- [ ] No uncommitted version bump in `build.zig.zon` — the version bump is a release-commit done by this command, not a leftover.

If any of the above fail, fix them and re-invoke. **Don't proceed past a failing test.**

## Steps

### 1. Decide the new version

semver:
- **Patch** (X.Y.Z+1): bug fixes only; no API change; downstream consumers can upgrade without reading the changelog.
- **Minor** (X.Y+1.0): new features, additive only; no breaking change to the existing public surface.
- **Major** (X+1.0.0): breaking change to the public API surface (`zobra.*` symbols, method signatures, `build.zig.zon` shape).

For pre-1.0 (current): minor bumps for any meaningful behavioural addition; patch for fixes. Breaking changes are allowed in minors but should be called out at the top of the changelog entry.

### 2. Bump `build.zig.zon`

Edit `build.zig.zon`, change `.version = "X.Y.Z"` to the new value. **The release workflow verifies that the tag's semver matches this exactly** — mismatched means the workflow fails before publishing.

### 3. Update `CHANGELOG.md`

The workflow extracts the section between `## [X.Y.Z]` and the next `## [` heading. Format:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Added
- …

### Changed
- …

### Fixed
- …

### Removed (if any)
- …
```

The `## [X.Y.Z] - YYYY-MM-DD` line must be exact — that's what the awk extractor matches.

### 4. Commit + push the version-bump commit

```sh
git add build.zig.zon CHANGELOG.md
git commit -m "chore(release): v$NEW_VERSION"
git push
```

Don't tag yet. Let the version-bump commit reach origin/main first.

### 5. Tag and push the tag

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

This triggers `.github/workflows/release.yml`. The workflow:
1. Validates the tag is `vX.Y.Z` shape.
2. Validates `build.zig.zon`'s `.version` equals `X.Y.Z`.
3. Runs `zig fmt --check`, `zig build test`, `zig build test-e2e`.
4. Extracts the matching CHANGELOG section into release notes.
5. Creates the GitHub Release with the auto-generated source tarball.

### 6. Verify the release page

After the workflow finishes (check the Actions tab), visit:

```
https://github.com/shhac/zobra/releases/tag/vX.Y.Z
```

Confirm:
- Release notes match the CHANGELOG section.
- The "Source code (tar.gz)" link is the GitHub-generated tarball.
- The auto-generated install snippet (URL pointing at this exact tag) is in the notes.

### 7. (Optional) Sanity-check a consumer can fetch it

In a scratch project:

```sh
zig fetch --save https://github.com/shhac/zobra/archive/refs/tags/vX.Y.Z.tar.gz
```

Should print a hash and add zobra to `build.zig.zon`. Tagging a release where `zig fetch` doesn't resolve cleanly is a hard regression — open an issue and yank the tag.

## What this command should output

When invoked, propose the diff (version bump + changelog entry shape) and the exact commands to run. **Don't push without explicit user confirmation** — releases are visible and partly irreversible (tags can be force-deleted but GitHub Releases can leave stale links).

## What NOT to do

- **Don't skip the version-bump commit.** The workflow's `verify build.zig.zon version matches tag` step exists to catch this.
- **Don't tag from a dirty working tree.** The tarball will reflect uncommitted state.
- **Don't push the tag before the version-bump commit lands on `main`.** The workflow would race against the bump.
- **Don't include `oracle/`, `test/`, `design-docs/`, `scripts/`, `examples/` in the package paths.** `build.zig.zon`'s `paths` field is already correct (only `src/`, build files, LICENSE, README). Verify before bumping.
- **Don't force-push to a tag** to "fix" a bad release. Yank (`git push --delete origin vX.Y.Z`) and cut a new patch version instead — downstream `zig fetch` would otherwise see a different hash on the same URL.

## Related

- `.github/workflows/release.yml` — the publish workflow (source-only).
- `.github/workflows/ci.yml` — runs the same test + fmt checks on PRs.
- `CHANGELOG.md` — the source of release notes.
- `build.zig.zon` — `.version` is the source of truth for the release-tag match-check.
