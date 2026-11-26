// Tests for the dead-man's switch decision logic.
//
// The half that DECIDES whether to reboot is the half that gets tested: a false
// positive here reboots a live production host serving 30 sites. fetch is
// stubbed, so nothing leaves the process and no Hetzner call is ever made.
//
// Cases run STRICTLY SEQUENTIALLY. They share one globalThis.fetch, and running
// them concurrently let each overwrite the others' stub — which produced two
// confident, entirely bogus failures the first time this was written.
import assert from "node:assert";
import { runCheck, runRequired, speaksNow } from "../src/worker.js";

let pass = 0, fail = 0;
const check = (name, fn) => {
  try { fn(); pass++; console.log(`  ok   ${name}`); }
  catch (e) { fail++; console.log(`  FAIL ${name}\n       ${e.message}`); }
};

// `behaviour` maps a probe url (or "*") to an outcome, or to a list of outcomes
// INDEXED BY PROBE ROUND — round 0 is the first sweep, round 1 the recheck.
// An outcome is an HTTP status number, or "throw" for a transport failure.
function stubFetch(behaviour, calls) {
  let round = 0;
  const seen = new Set();
  return async (url) => {
    const u = String(url);
    if (u.includes("api.hetzner.cloud")) { calls.push(["reboot", u]); return new Response("{}", { status: 201 }); }
    if (u.includes("webhook")) { calls.push(["notify", u]); return new Response("", { status: 200 }); }
    if (seen.has(u)) { seen.clear(); round++; }
    seen.add(u);
    const seq = behaviour[u] ?? behaviour["*"];
    const outcome = Array.isArray(seq) ? (seq[round] ?? seq[seq.length - 1]) : seq;
    calls.push(["probe", u]);
    if (outcome === "throw") throw new Error("connect ECONNREFUSED");
    return new Response("", { status: outcome });
  };
}

const ENV = {
  PROBE_URLS: "https://a.example,https://b.example",
  RECHECK_DELAY_SECONDS: "0",
  HETZNER_API_TOKEN: "t", HETZNER_SERVER_ID: "1",
  OBX_WEBHOOK_URL: "https://webhook.example/hook",
};

async function run(behaviour, env = ENV) {
  const calls = [];
  globalThis.fetch = stubFetch(behaviour, calls);
  const out = await runCheck(env);
  return { out, calls };
}
const rebooted = (calls) => calls.filter(([k]) => k === "reboot").length;

{
  const { out, calls } = await run({ "*": 200 });
  check("all healthy -> up, never reboots", () => {
    assert.equal(out.verdict, "up");
    assert.equal(rebooted(calls), 0);
  });
}
{
  // A 502 means Caddy ANSWERED: the box is alive and rebooting it would be a
  // self-inflicted outage. The most important case in this file.
  const { out, calls } = await run({ "*": 502 });
  check("all 502 (app broken, host alive) -> up, never reboots", () => {
    assert.equal(out.verdict, "up");
    assert.equal(rebooted(calls), 0);
  });
}
{
  const { out, calls } = await run({ "https://a.example": "throw", "https://b.example": 200 });
  check("one dead service, others alive -> up, never reboots", () => {
    assert.equal(out.verdict, "up");
    assert.equal(rebooted(calls), 0);
  });
}
{
  // The bug this guards: three probed hostnames are Cloudflare-proxied, so a dead
  // box does not fail to connect — Cloudflare answers 522 on its behalf. Counting
  // that as reachable meant allDown could never be true and the switch could
  // never fire, while reporting green throughout the outage.
  const { out, calls } = await run({ "*": 522 });
  check("all 522 (cloudflare: origin unreachable) -> reboots", () => {
    assert.equal(out.verdict, "down");
    assert.equal(rebooted(calls), 1);
  });
}
{
  const { out, calls } = await run({ "*": 521 });
  check("all 521 (web server is down) -> reboots", () => {
    assert.equal(out.verdict, "down");
    assert.equal(rebooted(calls), 1);
  });
}
{
  // 525 is a TLS failure between Cloudflare and the origin, which an expired
  // certificate produces on a perfectly healthy box. Rebooting for that would be
  // a self-inflicted outage — and api.slotland.rumio.world was returning exactly
  // this while the box was fine.
  const { out, calls } = await run({ "*": 525 });
  check("all 525 (cloudflare<->origin TLS) -> NEVER reboots", () => {
    assert.equal(out.verdict, "up");
    assert.equal(rebooted(calls), 0);
  });
}
{
  // 520 is Cloudflare's catch-all for an origin that replied with something
  // unintelligible. The origin did reply, so the box is alive.
  const { out, calls } = await run({ "*": 520 });
  check("all 520 (origin replied, unintelligibly) -> NEVER reboots", () => {
    assert.equal(out.verdict, "up");
    assert.equal(rebooted(calls), 0);
  });
}
{
  // Mixed: proxied hosts report the box dead, one DNS-only host still answers.
  const { out, calls } = await run({
    "https://a.example": 522,
    "https://b.example": 200,
  });
  check("one proxied 522 but another host answering -> no reboot", () => {
    assert.equal(out.verdict, "up");
    assert.equal(rebooted(calls), 0);
  });
}
{
  const { out, calls } = await run({ "*": "throw" });
  check("all transport failures, twice -> reboots exactly once", () => {
    assert.equal(out.verdict, "down");
    assert.equal(out.rebooted, true);
    assert.equal(rebooted(calls), 1);
  });
}
{
  const { out, calls } = await run({ "*": ["throw", 200] });
  check("down, then recovered on the recheck -> no reboot", () => {
    assert.equal(out.verdict, "recovered");
    assert.equal(rebooted(calls), 0);
  });
}
{
  const { out, calls } = await run({ "*": "throw" }, { ...ENV, HETZNER_API_TOKEN: "", HETZNER_SERVER_ID: "" });
  check("missing credentials -> raises the alarm, claims no reboot", () => {
    assert.equal(out.rebooted, false);
    assert.equal(rebooted(calls), 0);
    assert.ok(calls.some(([k]) => k === "notify"));
  });
}
{
  const { out } = await run({ "*": 200 }, { ...ENV, PROBE_URLS: "" });
  check("empty probe list -> misconfigured, not 'down'", () => {
    assert.equal(out.verdict, "misconfigured");
  });
}

// ── required endpoints ───────────────────────────────────────────────────────
// 2026-11-26: the box was fine and api.rumio.world answered 502 for 38 minutes.
// The switch above calls that "up", correctly. These must call it down, and
// must never reboot for it.
const REQ = {
  REQUIRED_URLS: "https://api.example/health,https://api.example/relay",
  REQUIRED_RECHECK_SECONDS: "0",
  HETZNER_API_TOKEN: "t", HETZNER_SERVER_ID: "1",
  OBX_WEBHOOK_URL: "https://webhook.example/hook",
};
const SPEAKS = 0;                 // the first two minutes of a 10-minute slot
const QUIET = 4 * 60 * 1000;      // a later run in the same slot
async function required(behaviour, nowMs = SPEAKS, env = REQ) {
  const calls = [];
  globalThis.fetch = stubFetch(behaviour, calls);
  const out = await runRequired(env, nowMs);
  return { out, calls };
}
const notified = (calls) => calls.filter(([k]) => k === "notify").length;
{
  const { out, calls } = await required({ "https://api.example/health": 200, "https://api.example/relay": 400 });
  check("200 and a 400 (the relay answering) -> up, nothing said", () => {
    assert.equal(out.verdict, "up");
    assert.equal(notified(calls), 0);
  });
}
{
  const { out, calls } = await required({ "https://api.example/health": 502, "https://api.example/relay": 502 });
  check("502 twice -> down, said once, NEVER a reboot", () => {
    assert.equal(out.verdict, "down");
    assert.deepEqual(out.down, ["https://api.example/health", "https://api.example/relay"]);
    assert.equal(notified(calls), 1);
    assert.equal(rebooted(calls), 0);
  });
}
{
  const { out, calls } = await required({ "https://api.example/health": [502, 200], "https://api.example/relay": 400 });
  check("502 then 200 on the recheck -> recovered, nothing said", () => {
    assert.equal(out.verdict, "recovered");
    assert.equal(notified(calls), 0);
  });
}
{
  const { out, calls } = await required({ "https://api.example/health": 200, "https://api.example/relay": "throw" });
  check("one endpoint not answering -> down, names only that one", () => {
    assert.equal(out.verdict, "down");
    assert.deepEqual(out.down, ["https://api.example/relay"]);
    assert.equal(notified(calls), 1);
  });
}
{
  const { out, calls } = await required({ "*": 502 }, QUIET);
  check("still down later in the same 10 minutes -> down, not said again", () => {
    assert.equal(out.verdict, "down");
    assert.equal(out.said, false);
    assert.equal(notified(calls), 0);
  });
}
{
  const { out, calls } = await required({ "*": 502 }, SPEAKS, { ...REQ, REQUIRED_URLS: "" });
  check("no REQUIRED_URLS -> nothing asked", () => {
    assert.equal(out.verdict, "none");
    assert.equal(calls.length, 0);
  });
}
check("speaks once in each 10 minutes of 2-minute runs", () => {
  const runs = [0, 2, 4, 6, 8, 10, 12].map((m) => speaksNow(m * 60 * 1000 + 5000));
  assert.deepEqual(runs, [true, false, false, false, false, true, false]);
});

console.log(`\npassed=${pass} failed=${fail}`);
process.exit(fail === 0 ? 0 : 1);
