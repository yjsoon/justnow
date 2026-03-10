## Release and Distribution

This document is for maintainers preparing official macOS builds for GitHub Releases.

GitHub Actions no longer builds release artefacts for this repo. Releases are built, notarised and uploaded locally.

If present, `.env.release.local` is auto-loaded by the local release scripts. Use it for gitignored machine-local release credentials such as `APPLE_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, and `APPLE_API_KEY_ISSUER_ID`.

## Local packaging

You can build locally without GitHub Actions using:

```bash
chmod +x Scripts/local-release-build.sh
./Scripts/local-release-build.sh [version]
```

Artifacts are written to `dist/`:

- `dist/JustNow-<version>-macos.zip`
- `dist/JustNow-<version>-macos.dmg` (requires `create-dmg`)

The public product site and Sparkle appcast live under `site/`. Keep website deployment separate from binary artifact generation, and assume a root-mounted custom domain for public URLs.

## Distribution-ready artifacts

For upload-ready builds, pass Developer ID signing details to the script:

```bash
./Scripts/local-release-build.sh [version] --distribution --identity "Developer ID Application: Name (TEAMID)" --team TEAMID
```

The distribution mode mirrors the archived hosted release flow: it signs the app binary, re-signs Sparkle's nested helper content, signs the app bundle, then signs the `.dmg`, and verifies signatures along the way.

To produce a locally notarised and stapled DMG, add App Store Connect API key details:

```bash
./Scripts/local-release-build.sh [version] \
  --distribution \
  --notarize \
  --identity "Developer ID Application: Name (TEAMID)" \
  --team TEAMID \
  --api-key /path/to/AuthKey_KEYID.p8 \
  --api-key-id KEYID \
  --api-issuer ISSUER-UUID
```

If you are using an Individual App Store Connect API key, omit `--api-issuer`.

Local notarisation prerequisites:

- an imported Developer ID Application certificate in your keychain
- an App Store Connect API key (`.p8`)
- the API key ID
- the Developer Team ID
- the issuer ID for Team API keys

## Local publish flow

Use the local publish helper when you want to upload release artefacts to GitHub:

```bash
./Scripts/local-release-publish.sh v0.1.1 \
  --title "JustNow v0.1.1" \
  --identity "Developer ID Application: Name (TEAMID)" \
  --team TEAMID \
  --api-key /path/to/AuthKey_KEYID.p8 \
  --api-key-id KEYID \
  --api-issuer ISSUER-UUID
```

What the publish helper does:

- requires the tag to already exist on `origin`
- checks that the tag matches the Xcode `MARKETING_VERSION` and that `CURRENT_PROJECT_VERSION` is consistent across configs
- builds a local signed, notarised and stapled `.zip` and `.dmg`
- creates the GitHub release if needed, otherwise uploads with `--clobber`
- reads back the published GitHub release metadata and notes
- for stable releases, refreshes `site/releases.json`, regenerates `site/releases/index.html`, and rebuilds `site/appcast.xml`
- prints the final GitHub release URL

Draft and prerelease GitHub releases intentionally skip the public site and Sparkle appcast update steps for now. The main feed only tracks stable releases.

Optional publish flags:

- `--notes-file <path>` to use custom release notes
- `--draft` to keep the release as a draft
- `--prerelease` to mark it as a prerelease
- `--skip-build` to upload existing `dist/` artefacts without rebuilding

## Archived workflow

The previous GitHub-hosted release build workflow has been archived to:

- `.github/archived-workflows/release.yml.disabled`

This keeps the old CI recipe for reference while preventing tag pushes from producing hosted release artefacts.

## Public site

The repo also includes a static site for the product page, release notes, and future Sparkle appcast:

- `site/index.html`
- `site/releases.json`
- `site/releases/`
- `site/appcast.xml`

GitHub Actions may deploy that static site to GitHub Pages, but release binaries should continue to be built and notarised locally.
