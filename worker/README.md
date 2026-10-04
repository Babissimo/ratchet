# Ratchet sign-in service

A Cloudflare Worker at `auth.ratchet.babissimo.net` that holds Ratchet's FreeAgent OAuth client
ID and secret, so the app ships neither. FreeAgent registers only confidential clients (no
PKCE), and its API terms forbid hardcoding credentials into an app.

| Endpoint | Does |
|---|---|
| `GET /{production,sandbox}/authorize?state=…&code_challenge=…` | Redirects to FreeAgent's approval page with the client ID and this service's callback |
| `GET /callback` | Receives FreeAgent's redirect, redeems the code, and redirects to `ratchet://callback` with the tokens sealed |
| `POST /{production,sandbox}/token` | Hands over sealed tokens for their `code_verifier` (`authorization_code`), or refreshes them with the credentials added (`refresh_token`) |

The service stands in for the PKCE FreeAgent lacks. Ratchet sends an S256 `code_challenge` with
the authorize request, and the service seals it into the `state` it gives FreeAgent. When
FreeAgent redirects back, the service redeems the code at once and encrypts the tokens together
with that challenge; Ratchet gets only the sealed form, and `/token` opens it only for the
matching `code_verifier`. Any app can register the `ratchet://` scheme, so one that intercepts
the callback gets something it can neither read nor use, and the code is redeemed as soon as it
arrives. Sealed values expire after ten minutes.

Two gaps remain that only PKCE on FreeAgent's side would close, since it would bind the code
itself to the challenge. Another app can start a sign-in of its own, which the user would have
to approve on FreeAgent's page. And someone who learns a sign-in's sealed `state` from the
browser (its history, an extension) could pair it with a code for their own account, signing
that copy of Ratchet in as them.

It keeps and logs nothing. Only the grant fields it recognises are forwarded, the redirect URI is
fixed, bodies are capped at 4 KB, and code redemptions and token requests are limited to 10 a
minute per client IP (per /64 for IPv6).

Ratchet signs the user out on a 401 from the token endpoint and on nothing else. A refused
refresh token becomes a 401 whatever status FreeAgent gave it, and FreeAgent's own 401s pass
through. FreeAgent sends the same 401 for bad client credentials as for a dead grant, so a wrong
secret here signs every user out (see Deploy on rotating it).

## Develop

```bash
npm install
npm test
```

`npm run dev` serves it on `localhost:8787`, reading secrets from a gitignored `.dev.vars`:

```
FREEAGENT_CLIENT_ID=…
FREEAGENT_CLIENT_SECRET=…
SEALING_KEY=…
```

## Deploy

The app in FreeAgent's Developer Dashboard needs `https://auth.ratchet.babissimo.net/callback`
among its redirect URIs. Then:

```bash
npx wrangler secret put FREEAGENT_CLIENT_ID
npx wrangler secret put FREEAGENT_CLIENT_SECRET
openssl rand -base64 32 | npx wrangler secret put SEALING_KEY
npm run deploy
```

Wrangler prompts for the first two values. The first deploy creates the
`auth.ratchet.babissimo.net` DNS record and certificate.

To rotate the client secret, create a second one in the Developer Dashboard (FreeAgent allows
two at once), `secret put` it here, and only then revoke the old one. Rotating `SEALING_KEY`
fails only sign-ins in progress; refreshes don't use it.

On the Workers Free plan this shares the account's 100,000 requests a day with every other
Worker in it. A signed-in Ratchet makes at most about one request an hour, but every request
counts, refused ones included, so anyone can spend the quota; a Cloudflare rate-limiting rule on
the hostname would stop that before it reaches the Worker.
