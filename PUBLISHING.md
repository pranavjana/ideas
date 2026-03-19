# Publishing & Releases

## How releases work

1. Push a tag like `v0.2.0-alpha` to `main`
2. GitHub Actions workflow (`.github/workflows/release.yml`) runs:
   - Builds the app via `scripts/build-dmg.sh`
   - Signs the ZIP with Sparkle's `sign_update` tool
   - Generates `appcast.xml` and commits it to `main`
   - Creates a GitHub Release with DMG + ZIP attached
3. Installed apps pick up the update via Sparkle (reads `appcast.xml`)

## Quick release commands

```bash
# Delete old release if re-releasing the same version
gh release delete v0.X.0-alpha --yes
git push --delete origin v0.X.0-alpha
git tag -d v0.X.0-alpha

# Tag and push to trigger the workflow
git tag v0.X.0-alpha
git push origin v0.X.0-alpha
```

## Lessons learned

### Sparkle version comparison

Sparkle uses two version fields:

| Appcast field | Maps to | Purpose |
|---|---|---|
| `sparkle:version` | `CFBundleVersion` | **Internal comparison** (must be numeric or consistently comparable) |
| `sparkle:shortVersionString` | `CFBundleShortVersionString` | Display only |

The build script sets `CURRENT_PROJECT_VERSION=$(date +%Y%m%d)` (e.g. `20260319`). The appcast **must** use this same numeric build number for `sparkle:version`, not the marketing version string like `0.2.0-alpha`.

If `sparkle:version` is a string like `0.2.0-alpha` and the installed app has build number `20260309`, Sparkle does string comparison: `"0" < "2"`, thinks the installed version is newer, and shows "You're up to date".

### Sparkle signing

- The app has `SUPublicEDKey` in Info.plist, so Sparkle **requires** a valid `sparkle:edSignature` on the enclosure. Without it, updates are silently skipped (no error shown to user, just "You're up to date").
- The `sign_update` tool lives at `SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update` in DerivedData, **not** under `Sparkle.framework/../bin/`. The workflow `find` pattern must use `-name "sign_update"` broadly, not a framework-specific path.
- The `SPARKLE_PRIVATE_KEY` secret must be set in GitHub repo settings.

### Workflow caveats

- The workflow commits the updated `appcast.xml` to `main`, so after a release your local `main` will be behind. Always `git pull` before pushing.
- If re-releasing the same tag, you must delete both the GitHub release **and** the remote tag before re-creating.
