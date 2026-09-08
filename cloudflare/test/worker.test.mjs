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
import { runCheck } from "../src/worker.js";

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

console.log(`\npassed=${pass} failed=${fail}`);
process.exit(fail === 0 ? 0 : 1);
