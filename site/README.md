# Site

The page at <https://ratchet.babissimo.net>: a Cloudflare Worker serving `public/` as static
assets, with no script. Wrangler is pinned in `package.json` and deploys to the custom domain
named in `wrangler.jsonc`.

```bash
cd site
npm install
npm run dev
npm run deploy
```

The page copies three things by hand, so update it alongside them: the bezel path in
`public/index.html` is the shipped mark from `../design/icons/curve-long-thin-base.svg`, the
demo menu mirrors `../Sources/RatchetCore/MenuBuilder.swift`, and the Install section repeats
the Homebrew command and minimum macOS version from `../README.md`.
