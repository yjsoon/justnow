# Site And Updates

This repo carries the macOS app and its static public site: product page, release notes, and stable Sparkle appcast.

## Layout

- `JustNow/`: macOS app source
- `site/`: public Cloudflare Pages site
- `site/index.html`: landing page
- `site/releases.json`: source-of-truth public release metadata
- `site/releases/`: public release notes
- `site/appcast.xml`: stable Sparkle appcast URL

## Current State

- GitHub Releases remain the canonical home for signed `.zip` and `.dmg` artefacts.
- Site generation/preview is independent of app builds. Authorized stable publication includes the release's website updates and deployment unless the user excludes them; unrelated site deployment needs authorization.
- The public site assumes a root-mounted custom domain, so root-absolute paths such as `/styles.css` and `/appcast.xml` are intentional.
- Repository builds include Sparkle and point at `https://justnow.tk.sg/appcast.xml`.
- Stable release publishing should update `site/releases.json`, regenerate `site/releases/`, and rebuild `site/appcast.xml` from the exact ZIP uploaded to GitHub. See [release checks and script limitations](release-and-distribution.md#release-checks-and-current-limitations).
- Use `site/releases.json` and `site/appcast.xml` for checked-in release state; verify live endpoints when reporting what is currently deployed rather than relying on a version recorded in prose.

## Open Source Hosting

- This repo is intended to stay public, which means the `site/` source is public too.
- That is expected: the landing page, release notes, and appcast are public assets and can live alongside the app source in one repository.
- Only public material belongs in `site/` and related scripts. Keep private signing keys, Cloudflare credentials, and notarisation secrets out of git.

## Stable release flow

1. Build and sign locally; notarise and staple the DMG. The packaging flow does not staple the ZIP or its enclosed app.
2. Upload the signed `.zip` and `.dmg` to GitHub Releases.
3. Populate `site/releases.json` from the release notes and regenerate the public release notes page.
4. Generate and validate the Sparkle appcast against the exact uploaded ZIP.
5. Review and commit generated metadata, then deploy the intended committed site state to Cloudflare Pages and verify the public version, notes, feed, and links. Push/merge only within the authorized scope.

The publisher deploys by default and does not stop on appcast generation failure. Use `--skip-site-deploy` to stage validation before a separate deploy within the same authorized release, not to silently leave the website stale. Draft/prerelease publication intentionally leaves the stable website/feed unchanged.

## Local generation and preview

After editing `site/releases.json`, run from the repository root:

```bash
python3 Scripts/generate-site-content.py
```

This writes `site/releases/index.html`; inspect the diff. For generator tests, run in a disposable copy containing the script and site inputs instead of overwriting unrelated local edits. JSON parsing, output/link checks, and rendered inspection of affected site states are appropriate verification; no app build or production deployment is required.

Serve `site/` as the HTTP root for preview so root-absolute URLs work. In an Amp orb use a supervised service, for example:

```bash
amp orb service start justnow-site --command 'python3 -m http.server 8000 --directory site' --portal
```

Share the returned portal URL, not a loopback address. Preview only public/synthetic content. Do not include screen history, OCR text, private diagnostics, or credentials in the public site or review captures.

Rebuilding the signed feed outside publication uses:

```bash
./Scripts/generate-sparkle-appcast.sh vX.Y.Z
```

Replace the tag with the intended release. This is a signing operation using the Sparkle keychain account, not a harmless HTML preview command; it needs the corresponding authorization and signed ZIP in `dist/`.

## URL and hosting constraints

- Keep the appcast at a stable public URL such as `/appcast.xml`, even if the website structure changes later.
- Keep the site deployed at a root-mounted domain; if we ever move back to a project-site path, the root-absolute links will need to change.
- Prefer hosting release note pages in `site/releases/` and linking to them from appcast items.
- [Cloudflare Pages](cloudflare-pages.md) and `wrangler.jsonc` own deployment targets. GitHub Actions release/site workflows are archived; GitHub Pages is not the supported host.
