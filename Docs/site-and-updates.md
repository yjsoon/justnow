# Site And Updates

This repo now carries both the macOS app source and the static public site used for the product page, release notes, and future Sparkle appcast.

## Layout

- `JustNow/`: macOS app source
- `site/`: public Pages site
- `site/index.html`: landing page
- `site/releases.json`: source-of-truth public release metadata
- `site/releases/`: public release notes
- `site/appcast.xml`: stable Sparkle appcast URL

## Current State

- GitHub Releases remain the canonical home for signed `.zip` and `.dmg` artefacts.
- The public site is designed to be deployed independently from release artefact publishing.
- The public site assumes a root-mounted custom domain, so root-absolute paths such as `/styles.css` and `/appcast.xml` are intentional.
- Repository builds now include Sparkle and point at `https://justnow.tk.sg/appcast.xml`.
- Stable release publishing updates `site/releases.json`, regenerates `site/releases/`, and rebuilds `site/appcast.xml` from the uploaded archive.
- The currently published `v0.1.1` archive predates Sparkle, so the first fully signed Sparkle enclosure will arrive with the next Sparkle-enabled public release.

## Open Source Hosting

- This repo is intended to stay public, which means the `site/` source is public too.
- That is expected: the landing page, release notes, and appcast are public assets and can live alongside the app source in one repository.
- Only public material belongs in `site/` and related scripts. Keep private signing keys, Cloudflare credentials, and notarisation secrets out of git.

## Intended Sparkle Flow

1. Build and notarise the release artefacts locally as we do now.
2. Upload the signed `.zip` and `.dmg` to GitHub Releases.
3. Read the published GitHub release body back into `site/releases.json`.
4. Generate the Sparkle appcast from the signed archive.
5. Regenerate the public release notes page.
6. Deploy `site/` to GitHub Pages or the final product domain.

## Notes

- Keep the appcast at a stable public URL such as `/appcast.xml`, even if the website structure changes later.
- Keep the site deployed at a root-mounted domain; if we ever move back to a project-site path, the root-absolute links will need to change.
- Prefer hosting release note pages in `site/releases/` and linking to them from appcast items.
- Run `python3 Scripts/generate-site-content.py` after editing `site/releases.json` by hand.
- Run `./Scripts/generate-sparkle-appcast.sh vX.Y.Z` after producing a signed Sparkle-enabled archive if you need to rebuild the feed outside the publish helper.
- Site deployment is intentionally separate from app binary building; GitHub Actions may publish Pages, but release artefacts remain locally built and uploaded.
