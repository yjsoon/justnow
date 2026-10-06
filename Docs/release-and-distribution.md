# Release and Distribution

This document is for maintainers preparing official macOS builds for GitHub Releases.

Official distribution preparation, notarisation, and publication require authorization for those actions. Routine local-install signing is a separate permission; see [local development](local-development.md). An authorized stable publication includes the release's website metadata, release notes, appcast, and Cloudflare deployment unless the user excludes them. It does not authorize unrelated site/infrastructure changes, tag creation/movement, pushes/merges, or unrequested replacement of existing release assets.

GitHub Actions builds and publishes stable releases, the website, and the signed Sparkle feed on version-tag pushes. Local packaging/publishing remains available as an alternative. Both paths use `Scripts/local-release-build.sh` to sign the app and notarise/staple the DMG.

## GitHub Actions setup

The active [Release workflow](../.github/workflows/release.yml) runs on `macos-26`. It checks out the release tag, checks version/build consistency, runs Python release tests and Xcode unit tests, builds a universal Apple Silicon/Intel app, and signs/notarises the artifacts. Then [the CI publisher](../Scripts/ci-release-publish.py) prepares the release/site/feed, verifies the Sparkle key and signature, uploads/downloads and compares both artifacts, publishes the GitHub release, and deploys the existing Cloudflare Pages site. It fails rather than falling back to unsigned builds or deploying after feed-generation failure. Credentials use a temporary keychain with always-run cleanup.

Before the first run:

1. Land the workflow and scripts on the default branch. The tagged source must contain this workflow and the current scripts/tests. Tags must be `vX.Y.Z` and match the project's `MARKETING_VERSION`; increment `CURRENT_PROJECT_VERSION` for new Sparkle updates.
2. In **Repository Settings → Secrets and variables → Actions**, add the secrets below. Reuse the app's existing Developer ID identity/team, not an Apple Development or Developer ID Installer certificate.
3. Check that Actions is enabled and repository policy permits the workflow's `contents: write` permission for release asset upload. The built-in `GITHUB_TOKEN` is sufficient; no personal access token secret is needed for uploading assets.

| Secret | Value |
| --- | --- |
| `APPLE_SIGNING_IDENTITY` | Full existing identity, e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_TEAM_ID` | Existing Apple Developer team ID |
| `APPLE_SIGNING_CERTIFICATE_P12` | Base64-encoded `.p12` export containing the Developer ID Application certificate **and private key** |
| `APPLE_SIGNING_CERTIFICATE_PASSWORD` | Password protecting that `.p12` export |
| `APPLE_API_KEY` | Base64-encoded App Store Connect `.p8` key with notarisation access |
| `APPLE_API_KEY_ID` | API key ID |
| `APPLE_API_KEY_ISSUER_ID` | Issuer UUID for a Team API key; leave unset for an Individual API key |
| `SPARKLE_PRIVATE_KEY` | Exact text exported from the **existing** Sparkle signing key; do not base64-encode it again or generate a replacement key |
| `CLOUDFLARE_API_TOKEN` | API token with Account → Cloudflare Pages → Edit, restricted to the account owning `justnow-site` |

Also set the Actions **variable** `CLOUDFLARE_ACCOUNT_ID` to that existing account's 32-character ID. Before storing the token, verify the account, `justnow-site` project, `main` production branch, and `justnow.tk.sg` custom domain. CI checks that exact target through the Cloudflare API before preparation and again before deployment. It does not provision resources or alter Git integration/DNS. Restrict who can push `v*` tags: tag code can access these signing/deployment credentials.

On the signing Mac, use Keychain Access → **My Certificates** to export the existing Developer ID Application identity as a password-protected `.p12`. If export is unavailable, check that its private key is present. Do not commit either key file or print their encoded contents. With GitHub CLI authenticated as a repository administrator, upload files directly:

```bash
base64 < /private/path/DeveloperID.p12 | gh secret set APPLE_SIGNING_CERTIFICATE_P12 --repo yjsoon/justnow
base64 < /private/path/AuthKey_KEYID.p8 | gh secret set APPLE_API_KEY --repo yjsoon/justnow
```

Set the remaining secrets through the Settings UI or `gh secret set SECRET_NAME --repo yjsoon/justnow` (interactive input). No `APPLE_KEYCHAIN_PASSWORD` secret is needed; each job generates its own masked temporary password. Base64 is only transport encoding, not encryption.

Export the existing Sparkle key on the signing Mac without displaying it:

```bash
TOOLS_DIR="$(./Scripts/ensure-sparkle-tools.sh)"
KEY_DIR="$(mktemp -d)"
"$TOOLS_DIR/bin/generate_keys" --account sg.tk.JustNow -x "$KEY_DIR/sparkle-key"
gh secret set SPARKLE_PRIVATE_KEY --repo yjsoon/justnow < "$KEY_DIR/sparkle-key"
rm -rf "$KEY_DIR"
```

If export fails, stop and recover the original key. Generating a new key would break updates for existing installations. CI imports the exported key and compares its public key with the built app's `SUPublicEDKey` before publication.

### Running a release build

- **Manual build-only check:** use **Actions → Release → Run workflow** on the default branch with an existing matching tag containing the new scripts/tests. It signs/notarises the build and retains downloadable binaries for 14 days, but does **not** create a release or deploy the site. Confirm signatures, stapling, and installation on a Mac before relying on it for distribution. This does not exercise Sparkle/Cloudflare publication.
- **Stable release:** prepare the approved version/build bump and notes, create the version tag at the intended revision, then push that specific `vX.Y.Z` tag. The push is the publication trigger; it includes GitHub release creation and production website/feed deployment. Only push when those actions are authorised. Tag pushes made by another workflow using `GITHUB_TOKEN` will not trigger a new run.
- CI creates a draft with GitHub-generated release notes if none exists. To use curated notes, prepare a draft for the version tag before pushing it. CI uses its body and publishes it only after feed validation and both asset uploads/download checks succeed. Empty/unusable notes fail publication. Prerelease tags such as `v1.6.0-beta.1` and GitHub prereleases are deliberately rejected by this stable pipeline.
- Runs share one concurrency group to protect the stable feed; release one version at a time (GitHub can replace an older pending run with a newer pending run). Both the marketing version and build number must advance; an unchanged same-tag/build recovery is allowed. CI reads deployed metadata/feed, disables Sparkle's default three-version pruning, and checks that historical enclosure URLs, sizes, and signatures survive generation.
- Existing assets are never overwritten. CI can reuse an existing asset only if downloaded bytes exactly match the built artifact. A fresh rebuild may differ because of signing timestamps; inspect partial publication rather than blindly rerunning. Recovery should use the retained exact binaries/generated site and separate explicit authorization where replacement/deployment is needed. Do not combine the local publisher and CI uploads for the same release.

The ZIP contains a signed app, but this packaging flow staples only the DMG. Sparkle verifies the exact ZIP's EdDSA signature; CI compares its downloaded GitHub asset with the signed local ZIP before deploying the feed. It checks public metadata, notes, and feed bytes after deployment. GitHub publication and Cloudflare deployment are not atomic: a failed deployment can leave a published release with the old website/feed; the job reports failure, not complete publication.

CI retains the generated `site/` artifact for 90 days and does **not** push generated files or rewrite tags. The deployed `releases.json` and `appcast.xml` are the CI release ledger. Reconcile `site/releases.json`, `site/releases/index.html`, and `site/appcast.xml` from the successful run's artifact into source control before unrelated site deployments; otherwise a manual deployment from stale checked-in files can roll back the public feed. Deployment metadata records the tag commit plus dirty generated files, not a fictitious `main` source commit.

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

These are historical references, not supported publishing paths. The active `.github/workflows/release.yml` reuses the current packager and deploys to Cloudflare Pages, not GitHub Pages. `unit-tests.yml` and `opencode.yml` do not publish releases.

## Public site

The repo includes a static site for the product page, release notes, and stable Sparkle appcast:

- `site/index.html`
- `site/releases.json`
- `site/releases/`
- `site/appcast.xml`

Stable release publication includes updating the public site on Cloudflare Pages unless excluded by the user. Site-only work can be previewed independently and needs deployment authorization to go live. See [site and updates](site-and-updates.md); GitHub Pages is not a supported release path.
