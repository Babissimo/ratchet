# Site

The page at <https://ratchet.babissimo.net>: a Cloudflare Worker serving `public/` as static
assets, with no script. Wrangler is pinned in `package.json` and deploys to the custom domain
named in `wrangler.jsonc`.

```bash
cd site
npm install
npm run dev
```

## Deploy

A push to `main` that touches `site/` deploys it through `.github/workflows/site.yml`; a pull
request that touches it gets a dry run. To redeploy `main` without a change, run the workflow
from the Actions tab.

The deploy reads one repository secret, `CLOUDFLARE_API_TOKEN`. Make it under Account API
tokens in the Cloudflare dashboard from the "Edit Cloudflare Workers" template, scoped to this
account and the `babissimo.net` zone, then store it with:

```bash
gh secret set CLOUDFLARE_API_TOKEN -R Babissimo/ratchet
```

`npm run deploy` from a machine signed in with `wrangler login` still works, but the next deploy
from `main` replaces whatever it published.

## Kept in step by hand

The page copies three things, so update it alongside them: the bezel path in
`public/index.html` is the shipped mark from `../design/icons/curve-long-thin-base.svg`, the
demo menu mirrors `../Sources/RatchetCore/MenuBuilder.swift`, and the Install section repeats
the Homebrew command and minimum macOS version from `../README.md`.
