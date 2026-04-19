# Permiso attribution

The Swift sources in this directory are adapted from the `Permiso` reference
implementation by Sasha Zats, published at https://github.com/zats/permiso.

At the time of vendoring (April 2026), the upstream repository does not
declare a licence. It is published as a public demo of the "Codex-style"
Screen Recording permission flow. The adaptation here:

- renames `OverlayWindowController` to `PermisoOverlayWindowController` to
  avoid colliding with JustNow's existing overlay controller;
- drops `public`/`Sendable` annotations that are unnecessary for in-app use;
- tightens `PermisoHostApp.current()` to treat empty `CFBundleDisplayName`
  values as missing so the fallback chain still reaches `CFBundleName`;
- switches `PermisoAssistant` to pause its 150ms poll while System Settings
  is not frontmost and resume it via `didActivateApplicationNotification`.

If you intend to ship this code in a publicly distributed binary, please
contact the upstream author to confirm licensing terms.
