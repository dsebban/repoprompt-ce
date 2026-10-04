<script lang="ts">
  import { onMount } from "svelte";
  import { app } from "../lib/app.svelte.ts";
  import { parseSessions, relativeTime, statusTone, type SessionInfo } from "../lib/parse.ts";
  import SessionDetail from "./SessionDetail.svelte";

  type Filter = "all" | "waiting_for_input" | "running";
  const filters: [Filter, string][] = [["all", "All"], ["waiting_for_input", "Needs me"], ["running", "Running"]];
  const rank: Record<string, number> = { waiting_for_input: 0, running: 1 };

  let filter = $state<Filter>("all");
  let sessions = $state<SessionInfo[]>([]);
  let loading = $state(false);
  let error = $state<string | null>(null);
  let openID = $state<string | null>(null);
  let now = $state(Date.now());

  const sorted = $derived(
    [...sessions].sort(
      (a, b) => (rank[a.status] ?? 2) - (rank[b.status] ?? 2) || (b.updatedAt ?? "").localeCompare(a.updatedAt ?? ""),
    ),
  );

  async function load() {
    loading = true;
    error = null;
    try {
      const args: Record<string, unknown> = { op: "list_sessions", limit: 40 };
      if (filter !== "all") args.state = filter;
      sessions = parseSessions(await app.rp("agent_manage", args));
      now = Date.now();
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  onMount(() => {
    void load();
  });
</script>

{#if openID}
  <SessionDetail id={openID} onclose={() => { openID = null; void load(); }} />
{:else}
  <div class="bar">
    {#each filters as [id, label] (id)}
      <button class="btn" class:primary={filter === id} onclick={() => { filter = id; void load(); }}>{label}</button>
    {/each}
    <button class="btn refresh" onclick={load} disabled={loading} aria-label="Refresh">{loading ? "…" : "↻"}</button>
  </div>
  <div class="scroll">
    {#if error}
      <p class="msg error">{error}</p>
    {:else if !loading && sorted.length === 0}
      <p class="msg muted">No sessions.</p>
    {/if}
    <ul>
      {#each sorted as s (s.id)}
        <li>
          <button onclick={() => (openID = s.id)}>
            <i class="dot tone-{statusTone(s.status)}"></i>
            <span class="main">
              <span class="name">{s.name}</span>
              <span class="sub muted">{s.status.replaceAll("_", " ")}{s.model ? ` · ${s.model}` : ""}</span>
            </span>
            <span class="time muted">{relativeTime(s.updatedAt, now)}</span>
          </button>
        </li>
      {/each}
    </ul>
  </div>
{/if}

<style>
  .bar { display: flex; gap: 6px; padding: 10px var(--gutter-r) 10px var(--gutter-l); overflow-x: auto; flex: none; }
  .refresh { margin-left: auto; min-width: 40px; }
  ul { list-style: none; margin: 0; padding: 0 var(--gutter-r) 16px var(--gutter-l); }
  li + li { border-top: 1px solid var(--line); }
  li button { width: 100%; display: flex; align-items: center; gap: 12px; min-height: 60px; padding: 10px 2px; border: 0; background: none; text-align: left; }
  .main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 500; }
  .sub, .time { font-size: 13px; }
  .msg { padding: 24px 16px; text-align: center; margin: 0; }
  .error { color: var(--bad); }
</style>
