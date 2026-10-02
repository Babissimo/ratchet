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

The page copies two things from the app by hand, so update it alongside them: the bezel path in
`public/index.html` is the shipped mark from `../design/icons/curve-long-thin-base.svg`, and the
demo menu mirrors `../Sources/RatchetCore/MenuBuilder.swift`.
