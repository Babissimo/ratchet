// SPDX-License-Identifier: GPL-3.0-or-later
// Ratchet's sign-in service. FreeAgent only registers confidential OAuth clients and its API
// terms forbid shipping the client credentials inside an app, so Ratchet signs in through here
// and this Worker adds the credentials on the way through.
//
//   GET  /{production|sandbox}/authorize?state=…&code_challenge=…  302 to FreeAgent's approval page
//   GET  /callback                                                FreeAgent's redirect; 302 to ratchet://callback
//   POST /{production|sandbox}/token                              Hands over the tokens, or refreshes them
//
// FreeAgent has no PKCE, so this Worker stands in for it. FreeAgent redirects here rather than to
// the app, the code is redeemed here at once, and Ratchet gets the tokens back sealed to its
// code_challenge. An app that intercepts the ratchet:// callback holds something it can neither
// read nor redeem.

const APP_CALLBACK = "ratchet://callback";
const CALLBACK_PATH = "/callback";

const FREEAGENT_API = {
  production: "https://api.freeagent.com/v2",
  sandbox: "https://api.sandbox.freeagent.com/v2",
};

const ROUTE = /^\/(production|sandbox)\/(authorize|token)$/;

// Ratchet sends a UUID state and FreeAgent's codes and refresh tokens are short; the caps only
// stop the Worker relaying arbitrary payloads under Ratchet's credentials.
const MAX_STATE_LENGTH = 128;
const MAX_TOKEN_LENGTH = 1024;
const MAX_BODY_BYTES = 4096;

// RFC 7636: an S256 challenge is base64url(SHA-256(verifier)), always 43 characters.
const CODE_CHALLENGE = /^[A-Za-z0-9_-]{43}$/;
const CODE_VERIFIER = /^[A-Za-z0-9._~-]{43,128}$/;

// Long enough to sign in to FreeAgent on the way; Ratchet stops waiting sooner.
const SEAL_LIFETIME_MS = 10 * 60 * 1000;
const IV_BYTES = 12;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const route = url.pathname.match(ROUTE);
    const environment = route?.[1];
    const endpoint = url.pathname === CALLBACK_PATH ? "callback" : route?.[2];
    if (!endpoint) return oauthError(404, "not_found", "No such endpoint");

    if (!env.FREEAGENT_CLIENT_ID || !env.FREEAGENT_CLIENT_SECRET) {
      return oauthError(500, "server_error", "Ratchet's sign-in service has no FreeAgent credentials");
    }

    if (endpoint === "token") {
      if (request.method !== "POST") return methodNotAllowed("POST");
      return token(request, environment, env);
    }
    if (request.method !== "GET") return methodNotAllowed("GET");
    if (endpoint === "authorize") return authorize(url, environment, env);
    return callback(request, url, env);
  },
};

async function authorize(url, environment, env) {
  const state = url.searchParams.get("state");
  if (!state || state.length > MAX_STATE_LENGTH) {
    return oauthError(400, "invalid_request", "Missing or overlong state");
  }
  const challenge = url.searchParams.get("code_challenge");
  if (!CODE_CHALLENGE.test(challenge ?? "")) {
    return oauthError(400, "invalid_request", "Missing or malformed code_challenge");
  }
  const key = await importSealingKey(env.SEALING_KEY);
  if (!key) return missingSealingKey();
  const approve = new URL(`${FREEAGENT_API[environment]}/approve_app`);
  approve.search = new URLSearchParams({
    client_id: env.FREEAGENT_CLIENT_ID,
    response_type: "code",
    redirect_uri: callbackURI(url),
    state: await seal(key, "state", { environment, challenge, state }),
  }).toString();
  return redirect(approve.toString());
}

// FreeAgent's reply, approved or not, goes back to Ratchet with Ratchet's own state. A code is
// redeemed here, before anything else can use it, and only the sealed tokens go on.
async function callback(request, url, env) {
  const key = await importSealingKey(env.SEALING_KEY);
  if (!key) return missingSealingKey();
  const started = await unseal(key, "state", url.searchParams.get("state"));
  if (!started) {
    return new Response("This sign-in link has expired or isn't valid. Start again from Ratchet's menu.\n", {
      status: 400,
      headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
    });
  }
  const { environment, challenge, state } = started;
  const code = url.searchParams.get("code");
  if (!isPlausibleToken(code)) {
    const reply = { state };
    for (const name of ["error", "error_description"]) {
      const value = url.searchParams.get(name);
      if (value) reply[name] = value;
    }
    return redirectToApp(reply);
  }

  // Never access_denied, which Ratchet takes to mean the user declined.
  const failed = (description) => redirectToApp({ state, error: "server_error", error_description: description });
  if (!(await withinRateLimit(request, env))) return failed("too many sign-in attempts, try again in a minute");
  const form = new URLSearchParams({ grant_type: "authorization_code", code, redirect_uri: callbackURI(url) });
  const upstream = await callFreeAgent(environment, form, env);
  if (!upstream) return failed("no response from FreeAgent");
  const tokens = parseJSON(upstream.body);
  if (upstream.status !== 200 || typeof tokens?.access_token !== "string") {
    return failed(`code refused: ${typeof tokens?.error === "string" ? tokens.error : `HTTP ${upstream.status}`}`);
  }
  return redirectToApp({ state, code: await seal(key, "tokens", { environment, challenge, tokens }) });
}

async function token(request, environment, env) {
  if (!(await withinRateLimit(request, env))) {
    return oauthError(429, "slow_down", "Too many sign-in requests, try again in a minute");
  }

  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.startsWith("application/x-www-form-urlencoded")) {
    return oauthError(415, "invalid_request", "Expected a form-encoded body");
  }
  const declaredLength = Number(request.headers.get("Content-Length") ?? 0);
  if (declaredLength > MAX_BODY_BYTES) return oauthError(413, "invalid_request", "Request body too large");
  const body = await readCappedText(request);
  if (body === null) return oauthError(413, "invalid_request", "Request body too large");

  const params = new URLSearchParams(body);
  switch (params.get("grant_type")) {
    case "authorization_code":
      return unsealTokens(params, environment, env);
    case "refresh_token":
      return refresh(params, environment, env);
    default:
      return oauthError(400, "unsupported_grant_type", "Expected authorization_code or refresh_token");
  }
}

// The "code" Ratchet got from the callback is the token response, sealed to its code_challenge.
async function unsealTokens(params, environment, env) {
  const verifier = params.get("code_verifier");
  if (!CODE_VERIFIER.test(verifier ?? "")) {
    return oauthError(400, "invalid_request", "Missing or malformed code_verifier");
  }
  const key = await importSealingKey(env.SEALING_KEY);
  if (!key) return missingSealingKey();
  const sealed = await unseal(key, "tokens", params.get("code"));
  if (sealed?.environment !== environment || sealed.challenge !== (await codeChallenge(verifier))) {
    return oauthError(400, "invalid_grant", "Sign-in expired or was started elsewhere; start again");
  }
  return Response.json(sealed.tokens, { headers: { "Cache-Control": "no-store" } });
}

async function refresh(params, environment, env) {
  const refreshToken = params.get("refresh_token");
  if (!isPlausibleToken(refreshToken)) {
    return oauthError(400, "invalid_request", "Missing or malformed refresh_token");
  }
  // Rebuilt from known fields only, so nothing the caller adds reaches FreeAgent.
  const form = new URLSearchParams({ grant_type: "refresh_token", refresh_token: refreshToken });
  const upstream = await callFreeAgent(environment, form, env);
  if (!upstream) return oauthError(502, "temporarily_unavailable", "Couldn't reach FreeAgent");

  // Ratchet signs the user out on a 401 from here and on nothing else. FreeAgent's own 401s pass
  // through: it answers a dead grant and bad client credentials alike with a bare "HTTP Basic:
  // Access denied.", so the credentials here must stay valid (see README.md on rotating them).
  // A refused refresh token is a 401 too, whatever status it arrives with (RFC 6749 gives
  // invalid_grant a 400).
  const sessionEnded = parseJSON(upstream.body)?.error === "invalid_grant";
  return new Response(upstream.body, {
    status: sessionEnded ? 401 : upstream.status,
    headers: { "Content-Type": upstream.contentType, "Cache-Control": "no-store" },
  });
}

// Undefined when FreeAgent can't be reached.
async function callFreeAgent(environment, form, env) {
  try {
    const response = await fetch(`${FREEAGENT_API[environment]}/token_endpoint`, {
      method: "POST",
      headers: {
        Authorization: `Basic ${btoa(`${env.FREEAGENT_CLIENT_ID}:${env.FREEAGENT_CLIENT_SECRET}`)}`,
        "Content-Type": "application/x-www-form-urlencoded",
        Accept: "application/json",
      },
      body: form,
    });
    return {
      status: response.status,
      contentType: response.headers.get("Content-Type") ?? "application/json",
      body: await response.text(),
    };
  } catch {
    return undefined;
  }
}

async function withinRateLimit(request, env) {
  // Absent in local tests; on Cloudflare it is configured in wrangler.jsonc.
  if (!env.TOKEN_RATE_LIMITER) return true;
  const key = rateLimitKey(request.headers.get("CF-Connecting-IP"));
  return (await env.TOKEN_RATE_LIMITER.limit({ key })).success;
}

// Must match a redirect URI registered for the app in FreeAgent's Developer Dashboard.
function callbackURI(url) {
  return new URL(CALLBACK_PATH, url.origin).toString();
}

async function codeChallenge(verifier) {
  return base64url(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

// SEALING_KEY is 32 random bytes in base64 (`openssl rand -base64 32`). Refreshes don't need it.
async function importSealingKey(secret) {
  const bytes = secret ? decodeBase64(secret) : undefined;
  if (bytes?.byteLength !== 32) return undefined;
  return crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}

function missingSealingKey() {
  return oauthError(500, "server_error", "Ratchet's sign-in service has no sealing key");
}

// AES-GCM, so a sealed value can be neither read nor forged without SEALING_KEY. The purpose is
// bound in as associated data, so a sealed state can't be passed off as sealed tokens.
async function seal(key, purpose, payload) {
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const plaintext = new TextEncoder().encode(JSON.stringify({ ...payload, exp: Date.now() + SEAL_LIFETIME_MS }));
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: new TextEncoder().encode(purpose) },
    key,
    plaintext,
  );
  const sealed = new Uint8Array(IV_BYTES + ciphertext.byteLength);
  sealed.set(iv);
  sealed.set(new Uint8Array(ciphertext), IV_BYTES);
  return base64url(sealed);
}

// Undefined for anything tampered with, sealed for another purpose, or expired.
async function unseal(key, purpose, text) {
  if (typeof text !== "string") return undefined;
  const sealed = decodeBase64(text);
  if (!sealed || sealed.byteLength <= IV_BYTES) return undefined;
  try {
    const plaintext = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: sealed.subarray(0, IV_BYTES), additionalData: new TextEncoder().encode(purpose) },
      key,
      sealed.subarray(IV_BYTES),
    );
    const payload = JSON.parse(new TextDecoder().decode(plaintext));
    return payload.exp > Date.now() ? payload : undefined;
  } catch {
    return undefined;
  }
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// Accepts both alphabets, padded or not.
function decodeBase64(text) {
  try {
    return Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (char) => char.charCodeAt(0));
  } catch {
    return undefined;
  }
}

// Stops reading past MAX_BODY_BYTES rather than buffering whatever arrives; a chunked body
// carries no Content-Length to refuse it by up front.
async function readCappedText(request) {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

// An IPv6 client usually holds a whole /64, so keying on the full address would let it rotate
// past the limit.
function rateLimitKey(ip) {
  if (!ip) return "unknown";
  if (!ip.includes(":")) return ip;
  // IPv4-mapped (::ffff:192.0.2.1) is one IPv4 client, not a /64 shared with every other.
  if (ip.includes(".")) return ip.slice(ip.lastIndexOf(":") + 1);
  const [head, tail] = ip.split("::");
  const groups = head ? head.split(":") : [];
  if (tail !== undefined) {
    const tailGroups = tail ? tail.split(":") : [];
    groups.push(...Array(Math.max(0, 8 - groups.length - tailGroups.length)).fill("0"), ...tailGroups);
  }
  return `${groups.slice(0, 4).map((group) => group.toLowerCase().padStart(4, "0")).join(":")}::/64`;
}

function isPlausibleToken(value) {
  return typeof value === "string" && value.length > 0 && value.length <= MAX_TOKEN_LENGTH;
}

function parseJSON(body) {
  try {
    return JSON.parse(body);
  } catch {
    return undefined;
  }
}

function redirect(location) {
  return new Response(null, { status: 302, headers: { Location: location, "Cache-Control": "no-store" } });
}

// Percent-encoded rather than URLSearchParams's form encoding: Foundation's URLComponents doesn't
// read "+" as a space.
function redirectToApp(fields) {
  const query = Object.entries(fields).map(([name, value]) => `${name}=${encodeURIComponent(value)}`);
  return redirect(`${APP_CALLBACK}?${query.join("&")}`);
}

// RFC 6749's error shape, which Ratchet already reads from FreeAgent's own token errors.
function oauthError(status, error, description) {
  return Response.json(
    { error, error_description: description },
    { status, headers: { "Cache-Control": "no-store" } },
  );
}

function methodNotAllowed(allowed) {
  const response = oauthError(405, "invalid_request", `Use ${allowed}`);
  response.headers.set("Allow", allowed);
  return response;
}
