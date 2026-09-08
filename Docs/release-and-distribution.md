# Release and Distribution

This document is for maintainers preparing official macOS builds for GitHub Releases.

Official distribution preparation, notarisation, and publication require authorization for those actions. Routine local-install signing is a separate permission; see [local development](local-development.md). An authorized stable publication includes the release's website metadata, release notes, appcast, and Cloudflare deployment unless the user excludes them. It does not authorize unrelated site/infrastructure changes, tag creation/movement, pushes/merges, or unrequested replacement of existing release assets.

GitHub Actions no longer builds release artefacts for this repo. Releases are built, signed, and uploaded locally; the packaging script notarises and staples the DMG when requested.

If present, `.env.release.local` (or `RELEASE_ENV_FILE`) is sourced by the local release scripts. Use it for gitignored machine-local credentials such as `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, and `APPLE_API_KEY_ISSUER_ID`. Inspect only necessary configuration without printing secrets. Environment overrides can enable distribution signing/notarisation; file presence is not authorization to use them. Sparkle appcast generation also uses the configured private keychain account in `Scripts/sparkle-config.sh`.

## Local packaging

For an authorized packaging task, replace `vX.Y.Z` with the artifact suffix (omit it for `local`):

```bash
./Scripts/local-release-build.sh vX.Y.Z
```

Artifacts are written to `dist/`:

- `dist/JustNow-<version>-macos.zip`
- `dist/JustNow-<version>-macos.dmg` (requires `create-dmg`)

Packaging alone does not upload or deploy. The public product site and Sparkle appcast live under `site/` at a root-mounted custom domain. GitHub Releases are the canonical home for signed binaries; do not duplicate them in the site.

## Distribution-ready artifacts

For upload-ready builds, pass Developer ID signing details to the script:

```bash
./Scripts/local-release-build.sh vX.Y.Z --distribution --identity "Developer ID Application: Name (TEAMID)" --team TEAMID
```

Distribution mode signs the app binary, re-signs Sparkle's nested helper content, signs the app bundle, then signs the `.dmg` if produced, and verifies signatures along the way. This is not notarisation by itself.

To produce a locally notarised and stapled DMG, add App Store Connect API key details:

```bash
./Scripts/local-release-build.sh vX.Y.Z \
  --distribution \
  --notarize \
  --identity "Developer ID Application: Name (TEAMID)" \
  --team TEAMID \
  --api-key /path/to/AuthKey_KEYID.p8 \
  --api-key-id KEYID \
  --api-issuer ISSUER-UUID
```

If you are using an Individual App Store Connect API key, omit `--api-issuer`.

The script creates the ZIP before submitting and stapling the DMG. Do not describe the ZIP or its enclosed app as stapled by this flow. If `create-dmg` is unavailable, packaging skips DMG creation and the notarisation block; verify expected artifacts and notarisation results rather than trusting the final success message alone.

Local notarisation prerequisites:

- an imported Developer ID Application certificate in your keychain
- an App Store Connect API key (`.p8`)
- the API key ID
- the Developer Team ID
- the issuer ID for Team API keys

## Local publish flow

Use the local publish helper only for authorized publication. Replace `vX.Y.Z` with the approved tag:

```bash
./Scripts/local-release-publish.sh vX.Y.Z \
  --title "JustNow vX.Y.Z" \
  --identity "Developer ID Application: Name (TEAMID)" \
  --team TEAMID \
  --api-key /path/to/AuthKey_KEYID.p8 \
  --api-key-id KEYID \
  --api-issuer ISSUER-UUID
```

What the publish helper does:

- requires the tag to already exist on `origin`
- checks that the tag matches the Xcode `MARKETING_VERSION` and that `CURRENT_PROJECT_VERSION` is consistent across configs
- builds a signed app ZIP and signed, notarised, stapled DMG unless `--skip-build` is used
- creates the GitHub release if needed, otherwise uploads with `--clobber`
- reads back the published GitHub release metadata and notes
- for stable releases with nonempty notes, refreshes `site/releases.json`, regenerates `site/releases/index.html`, and attempts to rebuild `site/appcast.xml` from the local ZIP uploaded in this flow
- deploys `site/` to Cloudflare Pages by default after those steps
- prints the final GitHub release URL

Draft and prerelease GitHub releases intentionally skip the public site and Sparkle appcast update steps for now. The main feed only tracks stable releases.

Optional publish flags:

- `--notes-file <path>` to use custom release notes
- `--draft` to create a draft release
- `--prerelease` to create a prerelease
- `--skip-build` to upload existing `dist/` artefacts without rebuilding
- `--skip-site-deploy` to regenerate metadata/feed without deploying `site/` to Cloudflare Pages; this does not skip Sparkle signing/keychain use

### Release checks and current limitations

Before invoking the helper, confirm the GitHub repository/account, approved tag and source revision, version/build numbers, signing team/identity, and artifact provenance. The helper checks tag existence and version strings, not that the checkout or prebuilt artifacts match the tag. Existing releases take the upload-with-`--clobber` path; confirm replacement is authorized. Draft/prerelease flags only apply on creation, not when uploading to an existing release.

For a stable release, complete the release/site outcome even if the script skips or warns:

- Provide nonempty release notes. Empty notes skip metadata, feed, and deployment; drafts/prereleases intentionally leave the stable feed unchanged.
- Check generated version/build numbers, release notes, enclosure URLs, sizes, and Sparkle signature against the exact uploaded ZIP. Verify expected app/DMG signing and DMG notarisation/stapling evidence. Appcast generation uses the local ZIP, not a freshly downloaded copy of the published asset.
- **Appcast failure is only a warning in the publisher.** It can still deploy a stale or invalid feed. For a validation checkpoint before deployment, use `--skip-site-deploy`, validate the generated files, then deploy explicitly as part of the same authorized stable release. This stages deployment; it does not omit the website update.
- Review and commit generated `site/releases.json`, `site/releases/`, and `site/appcast.xml` changes as part of the release work. The scripts do not commit them. Push/merge only when authorized. Deploy from the intended committed release state using [Cloudflare target checks](cloudflare-pages.md); if the helper already deployed dirty generated files, redeploy their committed state so deployment metadata matches the released content. Do not label an unrelated branch/commit as `main` merely because the helper defaults to it.
- Verify the public version, release notes, feed, and asset links after deployment. Report partial publication honestly; do not blindly rerun a command that may overwrite already-published assets.

These are operator checks, not safeguards already enforced by the scripts. Script hardening is separate work.

## Archived workflows

The previous GitHub-hosted release and site deployment workflows have been archived to:

- `.github/archived-workflows/release.yml.disabled`
- `.github/archived-workflows/site.yml.disabled`

These are historical references, not supported publishing paths. The active `.github/workflows/unit-tests.yml` and `opencode.yml` workflows do not replace the local release flow.

## Public site

The repo includes a static site for the product page, release notes, and stable Sparkle appcast:

- `site/index.html`
- `site/releases.json`
- `site/releases/`
- `site/appcast.xml`

Stable release publication includes updating the public site on Cloudflare Pages unless excluded by the user. Site-only work can be previewed independently and needs deployment authorization to go live. See [site and updates](site-and-updates.md); GitHub Pages is not a supported release path.
