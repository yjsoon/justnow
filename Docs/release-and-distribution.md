## Release and Distribution

This document is for maintainers preparing official macOS builds for GitHub Releases.

## Local packaging

You can build locally without GitHub Actions using:

```bash
chmod +x Scripts/local-release-build.sh
./Scripts/local-release-build.sh [version]
```

Artifacts are written to `dist/`:

- `dist/JustNow-<version>-macos.zip`
- `dist/JustNow-<version>-macos.dmg` (requires `create-dmg`)

## Distribution-ready artifacts

For upload-ready builds, pass Developer ID signing details to the script:

```bash
./Scripts/local-release-build.sh [version] --distribution --identity "Developer ID Application: Name (TEAMID)" --team TEAMID
```

The distribution mode signs the app binary, app bundle and `.dmg`, then verifies signatures.

## GitHub Actions release workflow

Release builds are published from version tags via `.github/workflows/release.yml`.

Required repository secrets for CI signing/notarisation:

- `APPLE_TEAM_ID`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_SIGNING_CERTIFICATE_P12` (base64-encoded `.p12`)
- `APPLE_SIGNING_CERTIFICATE_PASSWORD`
- `APPLE_KEYCHAIN_PASSWORD`
- `APPLE_API_KEY` (base64-encoded `.p8`)
- `APPLE_API_KEY_ID`
- `APPLE_API_KEY_ISSUER_ID`

With these configured, CI:

- builds the app
- applies release signing
- creates `.zip` and stylised `.dmg`
- notarises and staples the `.dmg`
- uploads artifacts to the release

## GitHub runner compatibility

The release workflow supports hosted macOS runners that may be on an older SDK:

- compatibility flags are injected for `macos-15` runners
- `LEGACY_MACOS_UI` is defined so UI code can compile when newer APIs are not available
- strict-concurrency checks are set to a compatibility level to avoid false CI failures
