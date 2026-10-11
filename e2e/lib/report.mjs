#!/usr/bin/env node
// Turns a run's reports into one result per test: each Bruno API flow and each
// Maestro flow gets its own line, and on GitHub its own commit status on the
// pull request (e2e/api/<flow>, e2e/web/<flow>, e2e/mobile/<flow>).
//
//   node e2e/lib/report.mjs api web          results of a finished run
//   node e2e/lib/report.mjs --pending web    mark the suite's tests as running
//
// The list of tests comes from the files on disk, not from the reports, so a
// test that never ran (the stack did not start, an earlier step failed) is
// reported as such instead of silently missing.
//
// Statuses are posted when E2E_STATUS_TOKEN, E2E_STATUS_REPO and
// E2E_STATUS_SHA are set (the workflow sets them); otherwise they are printed.

import { existsSync, readFileSync, readdirSync, writeFileSync, appendFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const E2E_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const THEMIS_DIR = resolve(E2E_DIR, "..");
const RUN_DIR = process.env.E2E_RUN_DIR || join(E2E_DIR, ".run");
const API_FLOWS = (process.env.E2E_API_FLOWS || "fleet-onboarding").split(/\s+/).filter(Boolean);
const MAESTRO_DIRS = { web: "fleet-web", mobile: "fleet-app" };

const unescape = (s) =>
  s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");

function attrs(text) {
  const out = {};
  for (const m of text.matchAll(/([\w:-]+)="([^"]*)"/g)) out[m[1]] = unescape(m[2]);
  return out;
}

// Enough XML for the two JUnit dialects in use (Bruno CLI and Maestro).
function elements(xml, tag) {
  const re = new RegExp(`<${tag}\\b([^>]*?)(?:/>|>([\\s\\S]*?)</${tag}>)`, "g");
  return [...xml.matchAll(re)].map((m) => ({ attrs: attrs(m[1]), body: m[2] || "" }));
}

function failureOf(testcase) {
  const m = testcase.body.match(/<(failure|error)\b([^>]*?)(?:\/>|>([\s\S]*?)<\/\1>)/);
  if (!m) return null;
  const text = attrs(m[2]).message || unescape(m[3] || "").replace(/<!\[CDATA\[|\]\]>/g, "");
  return text.replace(/\s+/g, " ").trim() || "failed";
}

const read = (path) => (existsSync(path) ? readFileSync(path, "utf8") : null);
const seconds = (s) => {
  const n = Math.round(Number(s) || 0);
  return n >= 60 ? `${Math.floor(n / 60)}m ${n % 60}s` : `${n}s`;
};

function suiteResults() {
  const out = {};
  for (const line of (read(join(RUN_DIR, "results.tsv")) || "").split("\n")) {
    const [suite, result, note] = line.split("\t");
    if (suite) out[suite] = { result, note };
  }
  return out;
}

function notRun(suite, ran) {
  if (ran[suite]?.result === "skip") {
    return { state: "error", description: `Skipped: ${ran[suite].note || "this machine cannot run it"}` };
  }
  return { state: "error", description: "Did not run (the stack or an earlier step failed; see the job log)" };
}

function apiCheck(flow, ran) {
  const xml = read(join(RUN_DIR, "api", `${flow}.junit.xml`));
  if (!xml) return notRun("api", ran);
  const requests = elements(xml, "testsuite");
  let checks = 0, failed = 0, first = null, time = 0;
  for (const request of requests) {
    time += Number(request.attrs.time) || 0;
    for (const tc of elements(request.body, "testcase")) {
      checks += 1;
      const failure = failureOf(tc);
      if (failure) {
        failed += 1;
        first ??= `${request.attrs.name}: ${tc.attrs.name}`;
      }
    }
  }
  if (!requests.length) return { state: "error", description: "The report lists no requests" };
  if (failed) {
    return {
      state: "failure",
      description: `${failed} of ${checks} checks failed, first at "${first}"`,
    };
  }
  return {
    state: "success",
    description: `${requests.length} requests, ${checks}/${checks} checks passed (${seconds(time)})`,
  };
}

function maestroCheck(suite, flow, ran) {
  // The web suite writes one report for all its flows; the mobile suite runs
  // its flows one at a time and writes one report each.
  const xml = read(join(RUN_DIR, suite, flow, "junit.xml")) || read(join(RUN_DIR, suite, "junit.xml"));
  const tc = xml && elements(xml, "testcase").find((t) => (t.attrs.id || t.attrs.name) === flow);
  if (!tc) return notRun(suite, ran);
  const failure = failureOf(tc);
  if (failure || !/^(success|pass)/i.test(tc.attrs.status || "success")) {
    return { state: "failure", description: `Failed after ${seconds(tc.attrs.time)}: ${failure || tc.attrs.status}` };
  }
  return { state: "success", description: `Passed in ${seconds(tc.attrs.time)}` };
}

function expected(suite) {
  if (suite === "api") return API_FLOWS;
  const dir = join(THEMIS_DIR, "maestro", "tests", MAESTRO_DIRS[suite]);
  if (!existsSync(dir)) return [];
  return readdirSync(dir).filter((f) => f.endsWith(".yaml")).map((f) => f.slice(0, -5)).sort();
}

async function post(check) {
  const { E2E_STATUS_TOKEN: token, E2E_STATUS_REPO: repo, E2E_STATUS_SHA: sha } = process.env;
  const api = process.env.GITHUB_API_URL || "https://api.github.com";
  const res = await fetch(`${api}/repos/${repo}/statuses/${sha}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    },
    body: JSON.stringify({
      context: check.context,
      state: check.state,
      description: check.description.slice(0, 140),
      ...(process.env.E2E_STATUS_URL ? { target_url: process.env.E2E_STATUS_URL } : {}),
    }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${check.context}`);
}

const args = process.argv.slice(2);
const pending = args[0] === "--pending";
const suites = (pending ? args.slice(1) : args).filter((s) => s === "api" || s in MAESTRO_DIRS);
if (!suites.length) {
  console.error("usage: report.mjs [--pending] <api|web|mobile>...");
  process.exit(2);
}

const ran = pending ? {} : suiteResults();
const checks = [];
for (const suite of suites) {
  for (const flow of expected(suite)) {
    const result = pending
      ? { state: "pending", description: "Running" }
      : suite === "api" ? apiCheck(flow, ran) : maestroCheck(suite, flow, ran);
    checks.push({ context: `e2e/${suite}/${flow}`, ...result });
  }
}

const canPost = process.env.E2E_STATUS_TOKEN && process.env.E2E_STATUS_REPO && process.env.E2E_STATUS_SHA;

if (!pending) {
  writeFileSync(join(RUN_DIR, "checks.json"), JSON.stringify(checks, null, 2) + "\n");
  const width = Math.max(...checks.map((c) => c.context.length));
  console.log(`[e2e] ${canPost ? "statuses posted to" : "statuses a pull request would show for"} this run`);
  for (const c of checks) {
    console.log(`   ${c.state.padEnd(8)} ${c.context.padEnd(width)}  ${c.description}`);
  }
  if (process.env.GITHUB_STEP_SUMMARY) {
    const icon = { success: "✅", failure: "❌", error: "⚠️" };
    appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      ["", "| Check | Result | Details |", "| --- | --- | --- |",
        ...checks.map((c) => `| \`${c.context}\` | ${icon[c.state]} ${c.state} | ${c.description.replace(/\|/g, "\\|")} |`),
        ""].join("\n"),
    );
  }
}

if (canPost) {
  // Reporting must never change the outcome of the run itself.
  for (const check of checks) {
    await post(check).catch((err) => console.error(`[e2e] warn could not post status: ${err.message}`));
  }
}
