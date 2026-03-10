## Cloudflare Pages Setup

This project uses Cloudflare Pages for the public site hosted at `https://justnow.tk.sg`.

## Repo configuration

- `wrangler.jsonc` defines the Pages project name as `justnow-site`.
- The deploy root is `site/`.
- `site/_headers` adds basic security headers and keeps the Sparkle appcast cache short.

## First-time setup

1. Sign in to Wrangler locally:

   ```bash
   npx wrangler login
   npx wrangler whoami
   ```

2. In Cloudflare, create a Pages project:
   - Workers & Pages
   - Create application
   - Pages
   - Connect to Git
   - Choose `yjsoon/justnow`

3. Use these build settings:
   - Production branch: `main`
   - Build command: none
   - Build output directory: `site`

4. Add the custom domain:
   - `justnow.tk.sg`

5. Confirm these URLs load over HTTPS:
   - `https://justnow.tk.sg/`
   - `https://justnow.tk.sg/releases/`
   - `https://justnow.tk.sg/appcast.xml`

## Notes

- This repo stays open source, so `site/` is intentionally public.
- Do not store Cloudflare credentials, Sparkle private keys, or Apple notarisation credentials in git.
- Publish the next stable Sparkle-enabled release only after the custom domain is live and serving the appcast.
