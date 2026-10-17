// Full-stack verification: wrangler dev (real Durable Object + built Svelte app, keyless
// faux model) ← real bridge ← fake RepoPrompt MCP server, driven by headless Chromium at
// iPhone size. Every RepoPrompt MCP call must succeed; screenshots land in SHOT_DIR.
//
//   npm run build && node test/verify-ui.mjs          (from web/)

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const PORT = Number(process.env.PORT ?? 8791);
const BASE = `http://127.0.0.1:${PORT}`;
const SHOT_DIR = path.resolve(process.env.SHOT_DIR ?? path.join(root, "web/test/screenshots"));
const LANE_B = "22222222-2222-2222-2222-222222222222";
const OVERSEER = "11111111-1111-1111-1111-111111111111";
const tmp = mkdtempSync(path.join(os.tmpdir(), "pi-overseer-verify-"));
const rpLog = path.join(tmp, "rp-calls.jsonl");
const children = [];

// iPhone Air: 420×912pt at 3×. As a home-screen web app (status bar style "default") the
// page starts below the status bar, so ~850pt tall with the 34pt home-indicator inset.
// Insets are approximate; Chromium has no safe areas, so they are injected (see below).
const IOS_UA =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";
const PROFILES = [
  { id: "air", label: "iPhone Air, portrait, light (full flow)", scheme: "light", full: true,
    viewport: { width: 420, height: 850 }, insets: { sat: 0, sab: 34, sal: 0, sar: 0 } },
  { id: "air-dark", label: "iPhone Air, portrait, dark", scheme: "dark", full: false,
    viewport: { width: 420, height: 850 }, insets: { sat: 0, sab: 34, sal: 0, sar: 0 } },
  { id: "air-landscape", label: "iPhone Air, landscape (Dynamic Island side)", scheme: "light", full: false,
    viewport: { width: 912, height: 420 }, insets: { sat: 0, sab: 21, sal: 62, sar: 62 } },
];

/** Problems an iPhone user would hit on the current screen. */
async function layoutIssues(page, profile) {
  return page.evaluate((insets) => {
    const issues = [];
    const vw = innerWidth;
    if (document.scrollingElement.scrollWidth > vw + 1) issues.push("page scrolls horizontally");
    for (const el of document.querySelectorAll(".scroll")) {
      if (el.scrollWidth > el.clientWidth + 1) issues.push("content wider than its scroll area");
    }
    for (const b of document.querySelectorAll("button")) {
      const r = b.getBoundingClientRect();
      if (r.width && r.height && r.height < 44) issues.push(`tap target ${Math.round(r.height)}pt: ${b.textContent.trim() || b.getAttribute("aria-label")}`);
    }
    for (const i of document.querySelectorAll("input, textarea")) {
      if (parseFloat(getComputedStyle(i).fontSize) < 16) issues.push(`input under 16px zooms on focus: ${i.placeholder}`);
    }
    for (const el of document.querySelectorAll("header, nav, form")) {
      const r = el.getBoundingClientRect();
      if (r.width && (r.bottom > innerHeight + 1 || r.right > vw + 1 || r.left < -1)) issues.push(`${el.tagName.toLowerCase()} off screen`);
    }
    const nav = document.querySelector("nav");
    if (nav) {
      const cs = getComputedStyle(nav);
      if (Math.abs(parseFloat(cs.paddingBottom) - insets.sab) > 1) issues.push("tab bar does not clear the home indicator");
      if (Math.abs(parseFloat(cs.paddingLeft) - insets.sal) > 1) issues.push("tab bar does not clear the left inset");
    }
    const header = document.querySelector("header");
    if (header && parseFloat(getComputedStyle(header).paddingLeft) < 16 + insets.sal - 1) issues.push("header under the left inset");
    return issues;
  }, profile.insets);
}
const failures = [];

function check(ok, what) {
  console.log(`${ok ? "  ✓" : "  ✗"} ${what}`);
  if (!ok) failures.push(what);
}

function start(cmd, args, opts) {
  const child = spawn(cmd, args, { ...opts, stdio: ["ignore", "pipe", "pipe"], detached: true });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));
  children.push(child);
  return { child, log: () => out };
}

async function waitFor(fn, what, ms = 60_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try {
      if (await fn()) return;
    } catch {
      /* retry */
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`timed out waiting for ${what}`);
}

const rpCalls = () =>
  readFileSync(rpLog, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));

async function main() {
  mkdirSync(SHOT_DIR, { recursive: true });

  console.log("Starting wrangler dev, bridge, fake RepoPrompt…");
  const worker = start(
    path.join(root, "worker/node_modules/.bin/wrangler"),
    ["dev", "--port", String(PORT), "--local", "--persist-to", path.join(tmp, "state"),
     "--var", "BRIDGE_TOKEN:bt", "--var", "PHONE_TOKEN:pt", "--var", "PI_PROVIDER:faux"],
    { cwd: path.join(root, "worker") },
  );
  await waitFor(async () => (await fetch(BASE)).ok, "wrangler dev");

  const tsx = path.join(root, "bridge/node_modules/.bin/tsx");
  const bridge = start(tsx, ["src/bridge.ts"], {
    cwd: path.join(root, "bridge"),
    env: {
      ...process.env,
      OVERSEER_URL: `ws://127.0.0.1:${PORT}/bridge`,
      BRIDGE_TOKEN: "bt",
      RPCE_MCP_COMMAND: tsx,
      RPCE_MCP_ARGS: "test/fake-rp-server.ts",
      FAKE_RP_LOG: rpLog,
      OVERSEER_POLL_MS: "1000",
      INPUT_POLL_MS: "1500",
    },
  });
  const auth = { headers: { Authorization: "Bearer pt" } };
  await waitFor(async () => (await (await fetch(`${BASE}/api/state`, auth)).json()).bridge, "bridge connection");

  console.log("Static app + auth");
  check((await fetch(BASE)).headers.get("content-type")?.includes("text/html"), "index served from assets");
  check((await fetch(`${BASE}/sessions/deep-link`)).ok, "SPA fallback for deep links");
  check((await fetch(`${BASE}/api/state`)).status === 401, "API rejects missing token");
  check((await fetch(`${BASE}/api/state`, { headers: { Authorization: "Bearer nope" } })).status === 401, "API rejects wrong token");
  const refused = await fetch(`${BASE}/api/rp`, {
    method: "POST",
    headers: { ...auth.headers, "content-type": "application/json" },
    body: JSON.stringify({ tool: "manage_workspaces", args: { action: "delete", workspace: "w1" } }),
  });
  check(refused.status === 403, "direct call refuses workspace delete before it reaches the Mac");

  console.log("Home-screen install (iOS)");
  const touchIcon = await fetch(`${BASE}/apple-touch-icon.png`);
  check(touchIcon.ok && touchIcon.headers.get("content-type") === "image/png", "apple-touch-icon.png served as PNG (iOS ignores SVG)");
  const manifest = await (await fetch(`${BASE}/manifest.webmanifest`)).json();
  const pngSizes = manifest.icons.filter((i) => i.type === "image/png").map((i) => i.sizes);
  check(manifest.display === "standalone" && pngSizes.includes("192x192") && pngSizes.includes("512x512"), "manifest: standalone with 192/512 PNG icons");
  const html = await (await fetch(BASE)).text();
  check(/viewport-fit=cover/.test(html) && /apple-mobile-web-app-status-bar-style" content="default"/.test(html), "viewport-fit=cover and a legible status bar style");

  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
  const shots = [];
  let currentPage = null;
  async function shoot(page, name) {
    await page.waitForTimeout(250);
    const file = path.join(SHOT_DIR, `${name}.png`);
    await page.screenshot({ path: file });
    shots.push(file);
  }

  for (const profile of PROFILES) {
    const { scheme, full } = profile;
    console.log(`UI: ${profile.label}`);
    const context = await browser.newContext({
      viewport: profile.viewport,
      screen: profile.viewport,
      deviceScaleFactor: 3,
      isMobile: true,
      hasTouch: true,
      userAgent: IOS_UA,
      colorScheme: scheme,
    });
    // Chromium has no safe areas; feed the app iPhone Air insets through its CSS vars.
    await context.addInitScript((insets) => {
      document.addEventListener("DOMContentLoaded", () => {
        const style = document.createElement("style");
        style.textContent = `:root{--sat:${insets.sat}px!important;--sab:${insets.sab}px!important;--sal:${insets.sal}px!important;--sar:${insets.sar}px!important}`;
        document.head.appendChild(style);
      });
    }, profile.insets);
    const page = await context.newPage();
    const layout = new Map();
    const inspect = async (screen) => {
      for (const issue of await layoutIssues(page, profile)) layout.set(`${screen}: ${issue}`, true);
      layout.set(`__screens:${screen}`, false);
    };
    currentPage = page;
    globalThis.__page = page;
    const consoleErrors = [];
    page.on("console", (m) => m.type() === "error" && consoleErrors.push(m.text()));
    page.on("pageerror", (e) => consoleErrors.push(String(e)));
    const directCalls = [];
    page.on("response", async (res) => {
      if (!res.url().endsWith("/api/rp")) return;
      const body = await res.json().catch(() => ({}));
      directCalls.push({ status: res.status(), isError: body.isError, error: body.error });
    });

    await page.goto(BASE);
    if (profile.id === "air") {
      await page.getByPlaceholder("Phone token").waitFor();
      await inspect("login");
      await shoot(page, "air-01-login");
    }
    if (await page.getByPlaceholder("Phone token").isVisible().catch(() => false)) {
      await page.getByPlaceholder("Phone token").fill("pt");
      await page.getByRole("button", { name: "Connect" }).click();
    }
    await page.locator("header .tone-ok").waitFor();
    check(true, "logged in; header shows Mac bridge online");

    // --- Chat: every agent tool through the faux model ----------------------
    const send = async (text) => {
      const before = await page.locator(".bubble").count();
      await page.getByPlaceholder("Tell Pi what to do…").fill(text);
      await page.getByRole("button", { name: "Send" }).click();
      await page.waitForFunction((n) => document.querySelectorAll(".bubble:not(.user)").length > 0 && document.querySelectorAll(".bubble").length >= n + 2, before);
      await page.waitForFunction(() => !document.querySelector(".working"));
    };
    if (full) {
      const toolPrompts = [
        `/tool overseer_setup {"adopt_session_id":"${OVERSEER}"}`,
        `/tool rp_workspaces {"action":"list"}`,
        `/tool rp_sessions {"state":"waiting_for_input"}`,
        `/tool rp_session_status {"session_ids":["${LANE_B}"]}`,
        `/tool rp_session_log {"session_id":"${LANE_B}","limit":2}`,
        `/tool rp_start_session {"message":"Fix the flaky login test","model_id":"engineer","session_name":"Flaky login"}`,
        `/tool rp_steer {"session_id":"33333333-3333-3333-3333-333333333333","message":"Run only LoginTests"}`,
        `/tool rp_cancel {"session_id":"33333333-3333-3333-3333-333333333333"}`,
        `/tool overseer_ask {"instruction":"Digest of all lanes","wait_seconds":10}`,
        `/tool memory_save {"kind":"workspace","subject":"repoprompt-ce","content":"Main Swift app; prefer engineer role","pinned":true}`,
        `/tool memory_save {"kind":"preference","subject":"replies","content":"Terse, lead with the answer"}`,
        `/tool memory_search {"query":"swift"}`,
        `/tool recent_activity {"limit":5}`,
        `/tool notify_phone {"title":"Test","body":"Verification push"}`,
      ];
      for (const p of toolPrompts) await send(p);
      const toolErrors = await page.locator(".bubble", { hasText: "TOOL ERROR" }).count();
      check(toolErrors === 0, `all ${toolPrompts.length} agent tools returned without error`);
      await send("What's running and what's waiting on me?");
      check(await page.locator(".bubble", { hasText: "faux: What's running" }).count() === 1, "plain prompt streams a reply");
    }
    await inspect("chat");
    await shoot(page, `${profile.id}-02-chat`);
    if (full) {
      // Chromium can't raise an iOS keyboard; reproduce what main.ts does when the
      // visual viewport shrinks to ~576pt (keyboard up) and check the composer stays usable.
      const kb = await page.evaluate(() => {
        const root = document.documentElement;
        const visible = innerHeight - 336;
        root.style.setProperty("--vv-height", `${visible}px`);
        root.classList.add("keyboard-open");
        const composer = document.querySelector("form textarea").getBoundingClientRect();
        const nav = document.querySelector("nav");
        return { composerBottom: composer.bottom, visible, navHidden: !nav || getComputedStyle(nav).display === "none" };
      });
      check(kb.composerBottom <= kb.visible && kb.navHidden, "keyboard up (simulated): composer stays above it, tab bar hides");
      await shoot(page, `${profile.id}-08-keyboard`);
      await page.evaluate(() => {
        const root = document.documentElement;
        root.classList.remove("keyboard-open");
        root.style.setProperty("--vv-height", `${visualViewport.height}px`);
      });
    }

    // --- Sessions: list, approve, steer, log ----------------------------------
    await page.getByRole("button", { name: "Sessions" }).click();
    await page.getByText("Lane B").first().waitFor();
    await inspect("sessions");
    await shoot(page, `${profile.id}-03-sessions`);
    if (full) {
      await page.getByRole("button", { name: "Needs me" }).click();
      await page.waitForTimeout(400);
      check((await page.locator("li").count()) === 1, "'Needs me' filter shows only the waiting session");
      await page.getByText("Lane B").click();
      await page.getByText("Needs your input").waitFor();
      check(await page.getByRole("button", { name: "Allow" }).isVisible(), "approval options rendered from the interaction");
      await inspect("approval");
      await shoot(page, `${profile.id}-04-approval`);
      await page.getByRole("button", { name: "Allow" }).click();
      await page.getByText("running", { exact: false }).first().waitFor();
      check(!(await page.getByText("Needs your input").isVisible()), "approval answered; session running");
      await page.getByPlaceholder("Steer this run…").fill("Also update the changelog");
      await page.getByRole("button", { name: "Send" }).click();
      await page.waitForTimeout(500);
      await page.getByRole("button", { name: "Read log" }).click();
      await page.locator("pre.log").waitFor();
      await inspect("session detail");
      await shoot(page, `${profile.id}-05-session-running`);
      await page.getByRole("button", { name: "‹ Sessions" }).click();
    }

    // --- Workspaces -----------------------------------------------------------
    await page.getByRole("button", { name: "Workspaces" }).click();
    await page.locator(".name", { hasText: "pi-durable-rp" }).waitFor();
    if (full) {
      await page.getByRole("button", { name: "Open" }).click();
      await page.waitForTimeout(500);
      check(!(await page.locator(".error").count()), "switching workspace succeeded");
    }
    await inspect("workspaces");
    await shoot(page, `${profile.id}-06-workspaces`);

    // --- Memory ---------------------------------------------------------------
    await page.getByRole("button", { name: "Memory" }).click();
    await page.locator(".memories", { hasText: "Main Swift app" }).waitFor();
    if (full) {
      await page.getByPlaceholder("Search memory…").fill("terse");
      await page.waitForTimeout(500);
      check((await page.locator(".memories li").count()) === 1, "memory search filters");
      await page.getByPlaceholder("Search memory…").fill("");
      await page.waitForTimeout(500);
    }
    await inspect("memory");
    await shoot(page, `${profile.id}-07-memory`);

    const screens = [...layout.keys()].filter((k) => k.startsWith("__screens:")).length;
    const issues = [...layout.keys()].filter((k) => !k.startsWith("__screens:"));
    check(issues.length === 0,
      `layout on ${screens} screens: no horizontal overflow, ≥44pt tap targets, ≥16px inputs, safe areas clear${issues.length ? `\n      ${issues.join("\n      ")}` : ""}`);

    check(directCalls.length > 0 && directCalls.every((c) => c.status === 200 && !c.isError),
      `${directCalls.length} direct /api/rp calls from the UI all succeeded`);
    check(consoleErrors.length === 0, `no browser console errors${consoleErrors.length ? `: ${consoleErrors.join(" | ")}` : ""}`);
    await context.close();
  }
  currentPage = null;
  await browser.close();

  console.log("RepoPrompt MCP calls (as seen by the fake RepoPrompt server)");
  const calls = rpCalls();
  const byOp = {};
  for (const c of calls) {
    const key = `${c.tool} ${c.args?.op ?? c.args?.action ?? ""}`.trim();
    byOp[key] ??= { ok: 0, err: 0 };
    byOp[key][c.isError ? "err" : "ok"]++;
  }
  for (const [k, v] of Object.entries(byOp).sort()) console.log(`    ${k.padEnd(32)} ok=${v.ok} err=${v.err}`);
  check(calls.length > 0 && calls.every((c) => !c.isError), `all ${calls.length} MCP calls reaching RepoPrompt succeeded`);
  check(!/refused/.test(bridge.log()), "bridge refused nothing");
  const state = await (await fetch(`${BASE}/api/state`, auth)).json();
  check(state.overseer === OVERSEER, "overseer binding persisted");
  check(state.activity.some((a) => a.kind === "overseer_turn"), "overseer Auto-wake digest reached the activity log");
  check(state.activity.some((a) => a.kind === "needs_input"), "needs-input event reached the activity log");

  console.log(`Screenshots: ${SHOT_DIR}`);
  void worker;
}

try {
  await main();
} catch (error) {
  failures.push(String(error));
  console.error(error);
  if (globalThis.__page) {
    await globalThis.__page.screenshot({ path: path.join(SHOT_DIR, "failure.png") }).catch(() => {});
    console.error("--- visible app text ---\n" + (await globalThis.__page.locator("#app").innerText().catch(() => "")));
  }
} finally {
  for (const c of children) {
    try {
      process.kill(-c.pid, "SIGTERM");
    } catch {
      /* already gone */
    }
  }
  rmSync(tmp, { recursive: true, force: true });
}
console.log(failures.length ? `\nFAILED (${failures.length})` : "\nALL CHECKS PASSED");
process.exit(failures.length ? 1 : 0);
