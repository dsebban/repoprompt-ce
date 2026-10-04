<script lang="ts">
  import { onMount } from "svelte";
  import { app } from "../lib/app.svelte.ts";
  import { parseSessions, renderMarkdown, statusTone, type SessionInfo } from "../lib/parse.ts";

  let { id, onclose }: { id: string; onclose: () => void } = $props();

  let info = $state<SessionInfo | null>(null);
  let error = $state<string | null>(null);
  let busy = $state(false);
  let message = $state("");
  let answer = $state("");
  let log = $state<string | null>(null);

  async function poll() {
    try {
      info = parseSessions(await app.rp("agent_run", { op: "poll", session_id: id })).find((s) => s.id === id) ?? info;
      error = null;
    } catch (e) {
      error = (e as Error).message;
    }
  }

  async function act(args: Record<string, unknown>) {
    busy = true;
    try {
      await app.rp("agent_run", { session_id: id, ...args });
      await poll();
    } catch (e) {
      error = (e as Error).message;
    } finally {
      busy = false;
    }
  }

  async function respond(response: string) {
    if (!info?.interactionID || !response.trim()) return;
    await act({ op: "respond", interaction_id: info.interactionID, response: response.trim() });
    answer = "";
  }

  async function steer() {
    if (!message.trim()) return;
    await act({ op: "steer", message: message.trim() });
    message = "";
  }

  async function readLog() {
    try {
      log = await app.rp("agent_manage", { op: "get_log", session_id: id, limit: 2 });
    } catch (e) {
      error = (e as Error).message;
    }
  }

  onMount(() => {
    void poll();
    // Only poll while something can change and the screen is visible.
    const timer = setInterval(() => {
      if (document.visibilityState === "visible" && info?.status === "running") void poll();
    }, 4000);
    return () => clearInterval(timer);
  });
</script>

<div class="top">
  <button class="btn" onclick={onclose}>‹ Sessions</button>
  <button class="btn" onclick={poll} aria-label="Refresh">↻</button>
</div>

<div class="scroll body">
  {#if !info && !error}
    <p class="muted">Loading…</p>
  {/if}
  {#if error}<p class="error">{error}</p>{/if}

  {#if info}
    <h2>{info.name}</h2>
    <p class="status"><i class="dot tone-{statusTone(info.status)}"></i>{info.status.replaceAll("_", " ")}{info.model ? ` · ${info.model}` : ""}</p>

    {#if info.status === "waiting_for_input"}
      <section class="card attention">
        <h3>Needs your input</h3>
        {#if info.interactionPrompt}<div class="md">{@html renderMarkdown(info.interactionPrompt)}</div>{/if}
        {#if info.options.length}
          <div class="row">
            {#each info.options as o (o.value)}
              <button class="btn" class:primary={/accept|approve|allow|yes/i.test(o.value)} disabled={busy} onclick={() => respond(o.value)}>{o.label}</button>
            {/each}
          </div>
        {/if}
        <form class="row" onsubmit={(e) => { e.preventDefault(); void respond(answer); }}>
          <input class="field" placeholder="Answer…" bind:value={answer} />
          <button class="btn primary" disabled={busy || !answer.trim()}>Answer</button>
        </form>
      </section>
    {/if}

    {#if info.assistantText}
      <section class="card">
        <h3>Latest reply</h3>
        <div class="md">{@html renderMarkdown(info.assistantText)}</div>
      </section>
    {/if}

    {#if info.status !== "waiting_for_input"}
      <form class="row" onsubmit={(e) => { e.preventDefault(); void steer(); }}>
        <input class="field" placeholder={info.status === "running" ? "Steer this run…" : "Send a follow-up…"} bind:value={message} />
        <button class="btn primary" disabled={busy || !message.trim()}>Send</button>
      </form>
    {/if}

    <div class="row">
      <button class="btn" onclick={readLog}>Read log</button>
      <button class="btn" onclick={() => app.ask(`Summarize session ${info!.name} (${id}): what it did and what it needs next.`)}>Ask Pi</button>
      {#if info.status === "running" || info.status === "waiting_for_input"}
        <button class="btn danger" disabled={busy} onclick={() => confirm(`Cancel the current run of ${info!.name}?`) && act({ op: "cancel" })}>Cancel run</button>
      {/if}
    </div>

    {#if log !== null}
      <pre class="log">{log}</pre>
    {/if}
  {/if}
</div>

<style>
  .top { display: flex; justify-content: space-between; padding: 10px 16px; }
  .body { padding: 0 16px 16px; display: flex; flex-direction: column; gap: 12px; }
  h2 { margin: 4px 0 0; font-size: 20px; overflow-wrap: anywhere; }
  h3 { margin: 0 0 6px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
  .status { margin: 0; display: flex; align-items: center; gap: 8px; color: var(--muted); }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: var(--radius); padding: 12px; display: flex; flex-direction: column; gap: 10px; }
  .attention { border-color: var(--wait); }
  .row { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
  .row .field { flex: 1; min-width: 0; }
  .log { white-space: pre-wrap; max-height: 50vh; overflow-y: auto; }
  .error { color: var(--bad); margin: 0; }
</style>
