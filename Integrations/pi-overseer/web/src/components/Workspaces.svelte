<script lang="ts">
  import { onMount } from "svelte";
  import { app } from "../lib/app.svelte.ts";
  import { parseWorkspaces, type WorkspaceInfo } from "../lib/parse.ts";

  let workspaces = $state<WorkspaceInfo[]>([]);
  let raw = $state("");
  let loading = $state(false);
  let error = $state<string | null>(null);
  let switching = $state<string | null>(null);

  async function load() {
    loading = true;
    error = null;
    try {
      raw = await app.rp("manage_workspaces", { action: "list" });
      workspaces = parseWorkspaces(raw);
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  async function open(w: WorkspaceInfo) {
    switching = w.id;
    try {
      await app.rp("manage_workspaces", { action: "switch", workspace: w.id });
      await load();
    } catch (e) {
      error = (e as Error).message;
    } finally {
      switching = null;
    }
  }

  const short = (p: string) => p.replace(/^\/(Users|home)\/[^/]+/, "~");

  onMount(() => {
    void load();
  });
</script>

<div class="bar">
  <strong>Workspaces</strong>
  <button class="btn" onclick={load} disabled={loading} aria-label="Refresh">{loading ? "…" : "↻"}</button>
</div>
<div class="scroll">
  {#if error}<p class="msg error">{error}</p>{/if}
  {#if !loading && !error && workspaces.length === 0}
    {#if raw}<pre class="raw">{raw}</pre>{:else}<p class="msg muted">No workspaces.</p>{/if}
  {/if}
  <ul>
    {#each workspaces as w (w.id)}
      <li>
        <div class="main">
          <span class="name">{w.name}{#if w.windows.length}<span class="badge">window {w.windows.join(", ")}</span>{/if}</span>
          <span class="sub muted">{w.paths.map(short).join(" · ") || "no folders"}</span>
        </div>
        <button class="btn" disabled={switching !== null} onclick={() => open(w)}>
          {switching === w.id ? "…" : w.windows.length ? "Focus" : "Open"}
        </button>
      </li>
    {/each}
  </ul>
  <div class="foot">
    <button class="btn" onclick={() => app.ask("Create a new RepoPrompt workspace. Ask me for the name and folder.")}>New workspace via Pi</button>
  </div>
</div>

<style>
  .bar { display: flex; align-items: center; justify-content: space-between; padding: 10px 16px; }
  ul { list-style: none; margin: 0; padding: 0 16px; }
  li { display: flex; align-items: center; gap: 12px; padding: 12px 2px; }
  li + li { border-top: 1px solid var(--line); }
  .main { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .name { font-weight: 500; display: flex; gap: 8px; align-items: center; }
  .badge { font-size: 11px; font-weight: 400; color: var(--ok); border: 1px solid currentColor; border-radius: 999px; padding: 0 6px; }
  .sub { font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .msg { padding: 24px 16px; text-align: center; margin: 0; }
  .error { color: var(--bad); }
  .raw { margin: 0 16px; white-space: pre-wrap; }
  .foot { padding: 16px; display: flex; justify-content: center; }
</style>
