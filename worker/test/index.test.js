// SPDX-License-Identifier: GPL-3.0-or-later
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, it, mock } from "node:test";
import worker from "../src/index.js";

const env = {
  FREEAGENT_CLIENT_ID: "test-id",
  FREEAGENT_CLIENT_SECRET: "test-secret",
  SEALING_KEY: Buffer.alloc(32, 7).toString("base64"),
};

// RFC 7636 appendix B's verifier.
const VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const CHALLENGE = createHash("sha256").update(VERIFIER).digest("base64url");

const TOKENS = { access_token: "a", refresh_token: "r", expires_in: 3600, token_type: "bearer" };

let upstreamCalls;
let upstreamResponse;

beforeEach(() => {
  upstreamCalls = [];
  upstreamResponse = () => Response.json(TOKENS);
  mock.method(globalThis, "fetch", async (url, init) => {
    upstreamCalls.push({ url, init, body: init.body.toString() });
    return upstreamResponse();
  });
});

afterEach(() => mock.restoreAll());

function get(path, environment = env) {
  return worker.fetch(new Request(`https://auth.example${path}`), environment);
}

function tokenRequest(form, { path = "/production/token", headers = {} } = {}) {
  return new Request(`https://auth.example${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", ...headers },
    body: new URLSearchParams(form).toString(),
  });
}

function location(response) {
  return new URL(response.headers.get("Location"));
}

function later(minutes) {
  const now = Date.now();
  mock.method(Date, "now", () => now + minutes * 60 * 1000);
}

// The state FreeAgent would echo back after sign-in starts at /authorize.
async function startSignIn({ environment = "production", state = "app-state", challenge = CHALLENGE } = {}) {
  const response = await get(`/${environment}/authorize?state=${state}&code_challenge=${challenge}`);
  return location(response).searchParams.get("state");
}

function callback(query, environment) {
  return get(`/callback?${new URLSearchParams(query)}`, environment);
}

// What Ratchet receives on ratchet://callback once FreeAgent has approved.
async function signIn(options = {}) {
  const state = await startSignIn(options);
  return location(await callback({ code: "c0de", state })).searchParams;
}

describe("authorize", () => {
  it("redirects to FreeAgent's approval page with the client ID and the service's callback", async () => {
    const response = await get(`/production/authorize?state=abc&code_challenge=${CHALLENGE}`);
    assert.equal(response.status, 302);
    const approve = location(response);
    assert.equal(approve.origin + approve.pathname, "https://api.freeagent.com/v2/approve_app");
    assert.equal(approve.searchParams.get("client_id"), "test-id");
    assert.equal(approve.searchParams.get("response_type"), "code");
    assert.equal(approve.searchParams.get("redirect_uri"), "https://auth.example/callback");
    const state = approve.searchParams.get("state");
    assert.ok(!state.includes("abc") && !state.includes(CHALLENGE), "the state is sealed");
  });

  it("ignores a caller-supplied redirect_uri", async () => {
    const response = await get(`/production/authorize?state=abc&code_challenge=${CHALLENGE}&redirect_uri=evil://x`);
    assert.deepEqual(location(response).searchParams.getAll("redirect_uri"), ["https://auth.example/callback"]);
  });

  it("uses the sandbox API for sandbox paths", async () => {
    const response = await get(`/sandbox/authorize?state=abc&code_challenge=${CHALLENGE}`);
    assert.ok(response.headers.get("Location").startsWith("https://api.sandbox.freeagent.com/v2/approve_app?"));
  });

  it("rejects a missing or overlong state and a missing or malformed challenge", async () => {
    const queries = [
      `?code_challenge=${CHALLENGE}`,
      `?state=&code_challenge=${CHALLENGE}`,
      `?state=${"x".repeat(129)}&code_challenge=${CHALLENGE}`,
      "?state=abc",
      `?state=abc&code_challenge=${CHALLENGE.slice(1)}`,
      `?state=abc&code_challenge=${CHALLENGE.slice(1)}=`,
    ];
    for (const query of queries) {
      const response = await get(`/production/authorize${query}`);
      assert.equal(response.status, 400, query);
    }
  });

  it("only answers GET", async () => {
    const response = await worker.fetch(
      new Request(`https://auth.example/production/authorize?state=abc&code_challenge=${CHALLENGE}`, { method: "POST" }),
      env,
    );
    assert.equal(response.status, 405);
    assert.equal(response.headers.get("Allow"), "GET");
  });
});

describe("callback", () => {
  it("redeems the code at once and hands Ratchet the tokens sealed, with Ratchet's own state", async () => {
    const state = await startSignIn({ state: "abc" });
    const response = await callback({ code: "c0de", state });

    assert.equal(upstreamCalls.length, 1);
    const [call] = upstreamCalls;
    assert.equal(call.url, "https://api.freeagent.com/v2/token_endpoint");
    assert.equal(call.init.headers.Authorization, `Basic ${btoa("test-id:test-secret")}`);
    assert.equal(
      call.body,
      "grant_type=authorization_code&code=c0de&redirect_uri=https%3A%2F%2Fauth.example%2Fcallback",
    );

    assert.equal(response.status, 302);
    const reply = location(response);
    assert.equal(`${reply.protocol}//${reply.host}`, "ratchet://callback");
    assert.deepEqual([...reply.searchParams.keys()], ["state", "code"]);
    assert.equal(reply.searchParams.get("state"), "abc");
    assert.match(reply.searchParams.get("code"), /^[A-Za-z0-9_-]+$/, "the tokens are sealed");
  });

  it("redeems sandbox codes against the sandbox", async () => {
    await signIn({ environment: "sandbox" });
    assert.equal(upstreamCalls[0].url, "https://api.sandbox.freeagent.com/v2/token_endpoint");
  });

  it("passes FreeAgent's refusal back with Ratchet's own state, spaces percent-encoded", async () => {
    const state = await startSignIn({ state: "abc" });
    const response = await callback({ error: "access_denied", error_description: "The user declined", state });
    assert.equal(
      response.headers.get("Location"),
      "ratchet://callback?state=abc&error=access_denied&error_description=The%20user%20declined",
    );
    assert.equal(upstreamCalls.length, 0);
  });

  it("reports a failed exchange as a server error, never as the user declining", async () => {
    const failures = [
      [() => new Response("HTTP Basic: Access denied.\n", { status: 401 }), "code refused: HTTP 401"],
      [() => Response.json({ error: "invalid_grant" }, { status: 400 }), "code refused: invalid_grant"],
      [() => Response.json({ token_type: "bearer" }), "code refused: HTTP 200"],
      [() => { throw new TypeError("network down"); }, "no response from FreeAgent"],
    ];
    for (const [failure, description] of failures) {
      upstreamResponse = failure;
      const reply = await signIn({ state: "abc" });
      assert.deepEqual(Object.fromEntries(reply), { state: "abc", error: "server_error", error_description: description });
    }
  });

  it("rate-limits redemption by client IP", async () => {
    const limitedEnv = { ...env, TOKEN_RATE_LIMITER: { limit: async () => ({ success: false }) } };
    const state = await startSignIn();
    const reply = location(await callback({ code: "c0de", state }, limitedEnv)).searchParams;
    assert.equal(reply.get("error"), "server_error");
    assert.equal(upstreamCalls.length, 0);
  });

  it("refuses a missing, forged, tampered, truncated, expired or misused state without calling FreeAgent", async () => {
    const state = await startSignIn();
    const flip = (text, index) => text.slice(0, index) + (text[index] === "A" ? "B" : "A") + text.slice(index + 1);
    const sealedTokens = (await signIn()).get("code");
    upstreamCalls = [];
    const states = [undefined, "", "abc", flip(state, 2), flip(state, state.length - 2), state.slice(0, 16), sealedTokens];
    for (const candidate of states) {
      const response = await callback({ code: "c0de", ...(candidate === undefined ? {} : { state: candidate }) });
      assert.equal(response.status, 400, String(candidate));
      assert.equal(response.headers.get("Location"), null);
    }

    later(11);
    assert.equal((await callback({ code: "c0de", state })).status, 400, "expired");
    assert.equal(upstreamCalls.length, 0);
  });

  it("refuses a state sealed under another key", async () => {
    const state = await startSignIn();
    const otherEnv = { ...env, SEALING_KEY: Buffer.alloc(32, 8).toString("base64") };
    assert.equal((await callback({ code: "c0de", state }, otherEnv)).status, 400);
  });
});

describe("token", () => {
  it("hands over the sealed tokens for the verifier they were sealed to, without calling FreeAgent again", async () => {
    const code = (await signIn()).get("code");
    const response = await worker.fetch(
      tokenRequest({ grant_type: "authorization_code", code, code_verifier: VERIFIER }),
      env,
    );
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), TOKENS);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    assert.equal(upstreamCalls.length, 1, "only the callback's exchange");
  });

  it("refuses sealed tokens without their verifier, and anything else offered as a code", async () => {
    const code = (await signIn()).get("code");
    const sandboxCode = (await signIn({ environment: "sandbox" })).get("code");
    const state = await startSignIn();
    const cases = [
      { code, code_verifier: "x".repeat(43) },
      { code: "c0de", code_verifier: VERIFIER },
      { code: state, code_verifier: VERIFIER },
      { code: sandboxCode, code_verifier: VERIFIER },
    ];
    for (const form of cases) {
      const response = await worker.fetch(tokenRequest({ grant_type: "authorization_code", ...form }), env);
      assert.equal(response.status, 400, JSON.stringify(form));
      assert.equal((await response.json()).error, "invalid_grant");
    }
    assert.equal(upstreamCalls.length, 2, "only the callbacks' exchanges");
  });

  it("refuses expired sealed tokens", async () => {
    const code = (await signIn()).get("code");
    later(11);
    const response = await worker.fetch(
      tokenRequest({ grant_type: "authorization_code", code, code_verifier: VERIFIER }),
      env,
    );
    assert.equal(response.status, 400);
  });

  it("refreshes with the client credentials, against the sandbox for sandbox paths", async () => {
    const response = await worker.fetch(
      tokenRequest({ grant_type: "refresh_token", refresh_token: "r1" }, { path: "/sandbox/token" }),
      env,
    );
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), TOKENS);
    assert.equal(upstreamCalls[0].url, "https://api.sandbox.freeagent.com/v2/token_endpoint");
    assert.equal(upstreamCalls[0].init.headers.Authorization, `Basic ${btoa("test-id:test-secret")}`);
    assert.equal(upstreamCalls[0].body, "grant_type=refresh_token&refresh_token=r1");
  });

  it("forwards only the fields a refresh needs", async () => {
    await worker.fetch(
      tokenRequest({
        grant_type: "refresh_token",
        refresh_token: "r1",
        redirect_uri: "evil://x",
        client_id: "someone-else",
        client_secret: "guess",
      }),
      env,
    );
    assert.equal(upstreamCalls[0].body, "grant_type=refresh_token&refresh_token=r1");
  });

  it("rejects other grants and malformed input without calling FreeAgent", async () => {
    const cases = [
      [tokenRequest({ grant_type: "client_credentials" }), 400],
      [tokenRequest({ grant_type: "password", username: "u", password: "p" }), 400],
      [tokenRequest({ grant_type: "authorization_code", code_verifier: VERIFIER }), 400],
      [tokenRequest({ grant_type: "authorization_code", code: "c0de" }), 400],
      [tokenRequest({ grant_type: "authorization_code", code: "c0de", code_verifier: "short" }), 400],
      [tokenRequest({ grant_type: "refresh_token" }), 400],
      [tokenRequest({ grant_type: "refresh_token", refresh_token: "x".repeat(1025) }), 400],
      [tokenRequest({ grant_type: "refresh_token", refresh_token: "r" }, { headers: { "Content-Type": "application/json" } }), 415],
      [tokenRequest({ grant_type: "refresh_token", refresh_token: "r".repeat(5000) }), 413],
      [new Request("https://auth.example/production/token"), 405],
      [new Request("https://auth.example/staging/token", { method: "POST" }), 404],
      [new Request("https://auth.example/production/token/extra", { method: "POST" }), 404],
    ];
    for (const [request, status] of cases) {
      const response = await worker.fetch(request, env);
      assert.equal(response.status, status, `${request.method} ${request.url}`);
      assert.ok((await response.json()).error);
    }
    assert.equal(upstreamCalls.length, 0);
  });

  it("passes FreeAgent's other refresh errors through unchanged", async () => {
    upstreamResponse = () => Response.json({ error: "invalid_request" }, { status: 400 });
    const response = await worker.fetch(tokenRequest({ grant_type: "refresh_token", refresh_token: "r" }), env);
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: "invalid_request" });
  });

  it("passes FreeAgent's 401 through, which it gives a dead grant and bad credentials alike", async () => {
    upstreamResponse = () =>
      new Response("HTTP Basic: Access denied.\n", { status: 401, headers: { "Content-Type": "text/html; charset=utf-8" } });
    const response = await worker.fetch(tokenRequest({ grant_type: "refresh_token", refresh_token: "dead" }), env);
    assert.equal(response.status, 401);
    assert.equal(await response.text(), "HTTP Basic: Access denied.\n");
  });

  it("reports a refused refresh token as a 401, so Ratchet sends the user back to sign-in", async () => {
    for (const status of [400, 401]) {
      upstreamResponse = () => Response.json({ error: "invalid_grant" }, { status });
      const response = await worker.fetch(tokenRequest({ grant_type: "refresh_token", refresh_token: "dead" }), env);
      assert.equal(response.status, 401, `upstream ${status}`);
      assert.deepEqual(await response.json(), { error: "invalid_grant" });
    }
  });

  it("refuses an oversized streamed body without a Content-Length", async () => {
    const chunk = new TextEncoder().encode("x".repeat(1024));
    let pulled = 0;
    const body = new ReadableStream({
      pull(controller) {
        pulled += 1;
        if (pulled > 100) controller.close();
        else controller.enqueue(chunk);
      },
    });
    const request = new Request("https://auth.example/production/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
      duplex: "half",
    });
    const response = await worker.fetch(request, env);
    assert.equal(response.status, 413);
    assert.ok(pulled < 10, `read ${pulled} KiB before refusing`);
    assert.equal(upstreamCalls.length, 0);
  });

  it("reports an unreachable FreeAgent as a 502", async () => {
    upstreamResponse = () => {
      throw new TypeError("network down");
    };
    const response = await worker.fetch(tokenRequest({ grant_type: "refresh_token", refresh_token: "r" }), env);
    assert.equal(response.status, 502);
  });

  it("rate-limits an IPv6 client by its /64", async () => {
    const keys = [];
    const limitedEnv = {
      ...env,
      TOKEN_RATE_LIMITER: {
        limit: async ({ key }) => {
          keys.push(key);
          return { success: true };
        },
      },
    };
    const ips = ["2001:db8:1:2:aaaa::1", "2001:DB8:1:2:bbbb:cccc:dddd:2", "2001:db8::5", "::ffff:192.0.2.1", "192.0.2.2"];
    for (const ip of ips) {
      await worker.fetch(
        tokenRequest({ grant_type: "refresh_token", refresh_token: "r" }, { headers: { "CF-Connecting-IP": ip } }),
        limitedEnv,
      );
    }
    assert.deepEqual(keys, [
      "2001:0db8:0001:0002::/64",
      "2001:0db8:0001:0002::/64",
      "2001:0db8:0000:0000::/64",
      "192.0.2.1",
      "192.0.2.2",
    ]);
  });

  it("rate-limits by client IP before calling FreeAgent", async () => {
    const keys = [];
    const limitedEnv = {
      ...env,
      TOKEN_RATE_LIMITER: {
        limit: async ({ key }) => {
          keys.push(key);
          return { success: false };
        },
      },
    };
    const response = await worker.fetch(
      tokenRequest({ grant_type: "refresh_token", refresh_token: "r" }, { headers: { "CF-Connecting-IP": "203.0.113.9" } }),
      limitedEnv,
    );
    assert.equal(response.status, 429);
    assert.deepEqual(keys, ["203.0.113.9"]);
    assert.equal(upstreamCalls.length, 0);
  });
});

describe("configuration", () => {
  it("fails closed without credentials", async () => {
    for (const environment of [{}, { ...env, FREEAGENT_CLIENT_SECRET: undefined }]) {
      const authorize = await get(`/production/authorize?state=abc&code_challenge=${CHALLENGE}`, environment);
      assert.equal(authorize.status, 500);
      const refresh = await worker.fetch(tokenRequest({ grant_type: "refresh_token", refresh_token: "r" }), environment);
      assert.equal(refresh.status, 500);
    }
    assert.equal(upstreamCalls.length, 0);
  });

  it("fails sign-in closed without a usable sealing key, but keeps refreshing", async () => {
    const state = await startSignIn();
    const code = (await signIn()).get("code");
    upstreamCalls = [];
    const keys = [undefined, Buffer.alloc(16, 7).toString("base64"), "not base64!"];
    for (const SEALING_KEY of keys) {
      const environment = { ...env, SEALING_KEY };
      const authorize = await get(`/production/authorize?state=abc&code_challenge=${CHALLENGE}`, environment);
      assert.equal(authorize.status, 500, `authorize, ${SEALING_KEY}`);
      assert.equal((await callback({ code: "c0de", state }, environment)).status, 500, `callback, ${SEALING_KEY}`);
      const tokens = await worker.fetch(
        tokenRequest({ grant_type: "authorization_code", code, code_verifier: VERIFIER }),
        environment,
      );
      assert.equal(tokens.status, 500, `authorization_code, ${SEALING_KEY}`);
      const refresh = await worker.fetch(tokenRequest({ grant_type: "refresh_token", refresh_token: "r" }), environment);
      assert.equal(refresh.status, 200, `refresh_token, ${SEALING_KEY}`);
    }
    assert.equal(upstreamCalls.length, keys.length, "only the refreshes");
  });

  it("answers unknown paths with 404 and only takes GET at the callback", async () => {
    assert.equal((await get("/")).status, 404);
    assert.equal((await get("/production/callback")).status, 404);
    const response = await worker.fetch(new Request("https://auth.example/callback", { method: "POST" }), env);
    assert.equal(response.status, 405);
  });
});
