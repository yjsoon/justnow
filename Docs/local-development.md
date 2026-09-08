# Local Development

Use this reference for build/test work and local app validation. Official distribution and publication are covered in [release and distribution](release-and-distribution.md).

## Build and test without replacing the app

Run from the repository root on a Mac with Xcode. The deployment target is macOS 15; `JustNow.xcodeproj/project.pbxproj` currently uses Swift 5 language mode. Do not confuse that with the compiler version. Check `xcodebuild -version` and `xcrun swift --version` on the build machine; the active test workflow uses a `macos-26` runner, not a pinned compiler version.

A build-only check that does not use signing credentials or install/launch the app:

```bash
xcodebuild build -project JustNow.xcodeproj -scheme JustNow \
  -configuration Release -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
```

For focused tests, select the affected test class or method with `-only-testing`. For example:

```bash
xcodebuild test -project JustNow.xcodeproj -scheme JustNow \
  -destination 'platform=macOS' -derivedDataPath build-tests-unsigned \
  -only-testing:JustNowTests/RetentionManagerTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
```

Omit `-only-testing` for the full suite. These signing flags follow the [unit-test workflow](../.github/workflows/unit-tests.yml). Preserve the `xcodebuild` exit status when piping logs (`set -o pipefail`).

Tests are app-hosted: Xcode runs the built test host, but `AppDelegate` skips normal startup capture/updater setup when `XCTestConfigurationFilePath` is present. This is not an installed-app smoke test. Storage tests must inject temporary directories into `FrameStore`, `TextCache`, and `FrameBuffer`; use synthetic images and isolated preferences/output locations. Do not point a test or repair script at the live Application Support store.

Scale verification to the change. Use focused tests plus a build for local app changes; broaden coverage for capture, storage, privacy, or lifecycle changes. Inspect rendered affected states for visual work and check interactions for behavioral work. Diagnose failures, fix those caused by the change, and rerun without asking at each step. Report unavailable checks explicitly. Documentation-only work needs accuracy/link checks, not Xcode; cloud work does not require a local app installation.

## Install a useful app change on a Mac

Useful day-to-day app fixes and improvements should normally finish with installation and launch from `/Applications/JustNow.app`. Do not reinstall after every intermediate build or for docs/site-only work. A graceful restart of the running app is authorized for this purpose; announce it rather than repeatedly asking.

1. Complete the relevant tests/build first. Inspect the installed app's signing authority, team, and designated requirement using `codesign -dv --verbose=4` and `codesign -dr -` with the app path. Compare the intended local signing inputs; reuse the existing matching Developer ID identity. If it is unavailable, would change, or no established identity exists, ask before selecting another mode.
2. Check the helper's prerequisites and effective configuration before interruption. It requires `trash`; the Developer ID path also invokes the release packager and its macOS packaging tools. `.env.release.local` (or `RELEASE_ENV_FILE`) is sourced by the helpers: inspect only necessary settings without printing secrets, and ensure distribution/notarisation environment overrides do not widen the authorized operation.
3. Announce that restarting loses memory-only recent detail. Graceful termination saves the latest frame from each display and flushes caches, not every recent frame. Ask the running app to quit through its normal AppKit quit path and wait for confirmed exit. If that fails, ask before force-killing; do not use the helper to bypass the wait. If the app restarts before replacement, repeat the graceful-exit check.
4. Prefer the existing helper rather than a raw copy/replacement recipe:

   ```bash
   ./Scripts/local-install-app.sh
   ```

5. Verify the installed signature matches the intended identity, that the process actually launched from `/Applications/JustNow.app`, and that the changed behavior works. Check capture/overlay behavior when relevant, with non-sensitive screen content. If launch fails, diagnose it; if available, `xcodebuildmcp macos launch --app-path "/Applications/JustNow.app"` is a fallback, not an assumed installed command.

Routine use of the existing matching Developer ID identity is authorized for local installation. The helper may produce local ZIP/DMG files as part of that build; this is not permission to notarise, publish those files, or prepare an official release.

### Current helper limitations

`local-install-app.sh` blocks fallback signing over an existing Developer ID installation when identity/team inputs are missing. It does **not** enforce equality between the existing and every configured/discovered Developer ID identity. Compare them before use; do not assume discovery selected the right one.

The helper still calls `pkill`, replaces the app using `trash` and a copy, and attempts `open`. It does not wait for the asynchronous normal-quit flush, and a failed `open` only prints a warning. The pre-exit check and post-install smoke test above are required; a successful helper exit is insufficient. Script hardening is separate work, not an existing safeguard.

## Screen Recording and TCC recovery

Keep both `/Applications/JustNow.app` and its signing identity stable to reduce permission churn. Never launch a raw unsigned test build as a substitute for real capture validation. Do not weaken or reset TCC, change identity, or delete history to make capture tests pass.

If capture fails after an evidenced signing change even though Screen Recording appears enabled, ask the user to remove only the JustNow entry in **System Settings → Privacy & Security → Screen Recording**, then relaunch and grant access again. This is conditional recovery, not routine installation cleanup. Preserve the app's first-launch flow: allow the native TCC prompt to resolve before showing additional app guidance. Persistent/transient capture recovery has other causes too; inspect non-content diagnostics before assuming a permission reset is needed.
