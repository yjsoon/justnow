# Cloudflare Pages

This project uses Cloudflare Pages for the public site hosted at `https://justnow.tk.sg`.

## Repo configuration

- `wrangler.jsonc` defines the Pages project name as `justnow-site`.
- The deploy root is `site/`.
- `site/_headers` adds basic security headers and keeps the Sparkle appcast cache short.
- `Scripts/deploy-public-site.sh` directly uploads the checked-out `site/` directory; it does not build the app or generate site content.

## Automated stable releases

The [Release action](../.github/workflows/release.yml) calls the deploy helper after publishing validated binaries and generating the signed feed. Configure the `CLOUDFLARE_API_TOKEN` Actions secret and `CLOUDFLARE_ACCOUNT_ID` Actions variable for the existing account, as described in [release setup](release-and-distribution.md#github-actions-setup). The token needs Account → Cloudflare Pages → Edit scoped to that account. CI verifies `justnow-site`, its `main` production branch, and `justnow.tk.sg` through the Pages API before deployment, then checks public metadata/notes/feed bytes. No project/domain/DNS provisioning or Git-integration changes are performed.

The payload is the tagged `site/` source plus generated metadata/feed, explicitly marked dirty in deployment metadata. CI retains the generated site artifact but does not push it to the repository. Reconcile successful generated release files into source control before separate manual website deployments, so stale checked-in files do not roll back the feed. A failed deploy can leave the GitHub release published with the previous site; inspect the job and artifacts before any recovery mutation.

## Authorization and target checks

An authorized stable release includes its version metadata, release notes, appcast, and website deployment unless excluded by the user. Other website deployments need explicit authorization. Previewing or verifying a site does not authorize deployment; release deployment does not authorize account/project/domain provisioning.

Before deployment:

1. Inspect `npx wrangler whoami` and the target project configuration. Confirm the intended account owns `justnow-site` and its `justnow.tk.sg` domain; successful authentication alone is not target verification. Stop if the account or target is ambiguous.
2. Check `wrangler.jsonc` and any `CLOUDFLARE_PAGES_*` environment/CLI overrides without exposing credentials. Confirm the intended branch/environment (production normally `main`), source revision, and generated site diff. Branch and commit labels must describe the content actually being deployed.
3. Validate site metadata, release notes, feed and links as applicable. The deploy helper allows dirty content (`--commit-dirty=true`); prefer the intended committed state and do not mistake a supplied commit hash for proof that the payload matches it.
4. Confirm any dashboard Git integration/automatic builds before a related push. Repository scripts use direct upload; neither the repo configuration nor archived GitHub Actions proves whether Cloudflare-side Git builds are enabled. Do not enable, disable, or reconfigure them without authorization.

## Deploying updates

From the repository root, after the checks above, deploy the current committed site state to the approved production target:

```bash
./Scripts/deploy-public-site.sh \
  --project-name justnow-site \
  --branch main \
  --commit-hash "$(git rev-parse HEAD)"
```

Use the approved branch/target for non-production work, not `main` by habit. The helper also accepts `--commit-message`. It deploys the local directory regardless of the commit metadata supplied.

Stable runs of `./Scripts/local-release-publish.sh` call this helper automatically unless `--skip-site-deploy` is passed. That flag can stage validation and a subsequent deployment within the authorized release; it does not remove the requirement to update the website. The publisher can warn on appcast failure and still deploy; follow [release checks](release-and-distribution.md#release-checks-and-current-limitations), not just its exit status.

After production deployment, verify the intended version/content and HTTPS responses at:

- `https://justnow.tk.sg/`
- `https://justnow.tk.sg/releases/`
- `https://justnow.tk.sg/appcast.xml`

Check enclosure/download links too. A deployment URL alone does not prove that the custom domain serves the new feed. For previews, inspect the returned preview URL instead.

## Provisioning or authentication changes

For a separately authorized setup task, inspect existing resources before creating anything. Authenticate locally if needed (`npx wrangler login`), then verify identity. Reuse the existing Pages project/domain where possible. The supported upload root is `site/`; generation happens locally, and the normal production branch is `main`.

Do not follow an old “Connect to Git” recipe automatically: dashboard integration, build triggers, domain attachment, and DNS are shared infrastructure decisions, not prerequisites to repeat during routine deployment.

## Notes

- This repo stays open source, so `site/` is intentionally public.
- Do not store Cloudflare credentials, Sparkle private keys, or Apple notarisation credentials in git.
- Keep the stable custom domain and appcast URL working for existing clients. Static generation/preview is documented in [site and updates](site-and-updates.md).
