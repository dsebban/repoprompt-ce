<script lang="ts">
  import { onMount } from "svelte";
  import { app, type MemoryItem } from "../lib/app.svelte.ts";
  import { relativeTime } from "../lib/parse.ts";

  let query = $state("");
  let memories = $state<MemoryItem[]>([]);
  let error = $state<string | null>(null);
  let timer: ReturnType<typeof setTimeout> | undefined;

  async function load() {
    try {
      const r = await app.api<{ memories: MemoryItem[] }>(`/api/memories?q=${encodeURIComponent(query)}`);
      memories = r.memories;
      error = null;
    } catch (e) {
      error = (e as Error).message;
    }
  }

  function search() {
    clearTimeout(timer);
    timer = setTimeout(load, 200);
  }

  async function forget(m: MemoryItem) {
    if (!confirm(`Forget “${m.subject}”?`)) return;
    await app.api(`/api/memories?id=${m.id}`, { method: "DELETE" });
    memories = memories.filter((x) => x.id !== m.id);
  }

  onMount(() => {
    void load();
    return () => clearTimeout(timer);
  });
</script>

<div class="scroll body">
  <section>
    <h3>Activity</h3>
    {#if app.activity.length === 0}<p class="muted">Nothing yet.</p>{/if}
    <ul class="activity">
      {#each app.activity.slice(0, 20) as a, i (i)}
        <li><span class="kind">{a.kind.replaceAll("_", " ")}</span> {a.text} <span class="muted">{relativeTime(a.at)}</span></li>
      {/each}
    </ul>
  </section>

  {#if app.summary}
    <section>
      <h3>Conversation summary</h3>
      <p class="summary">{app.summary}</p>
    </section>
  {/if}

  <section>
    <h3>Memories</h3>
    <input class="field" type="search" placeholder="Search memory…" bind:value={query} oninput={search} />
    {#if error}<p class="error">{error}</p>{/if}
    <ul class="memories">
      {#each memories as m (m.id)}
        <li>
          <div>
            <span class="tag">{m.kind}</span>{#if m.pinned}<span title="Pinned: in every prompt">📌</span>{/if}
            <strong>{m.subject}</strong>
            <p>{m.content}</p>
          </div>
          <button class="btn danger" onclick={() => forget(m)} aria-label="Forget {m.subject}">✕</button>
        </li>
      {/each}
    </ul>
    {#if memories.length === 0 && !error}<p class="muted">{query ? "No matches." : "Pi hasn't saved anything yet."}</p>{/if}
  </section>
</div>

<style>
  .body { padding: 12px var(--gutter-r) 16px var(--gutter-l); display: flex; flex-direction: column; gap: 20px; }
  h3 { margin: 0 0 8px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
  p { margin: 0; }
  ul { list-style: none; margin: 0; padding: 0; }
  .activity li { font-size: 14px; padding: 6px 0; border-bottom: 1px solid var(--line); }
  .kind { font-weight: 600; }
  .summary { font-size: 14px; white-space: pre-wrap; }
  .memories { margin-top: 8px; }
  .memories li { display: flex; gap: 8px; align-items: flex-start; padding: 10px 0; border-bottom: 1px solid var(--line); }
  .memories li > div { flex: 1; min-width: 0; }
  .memories .btn { min-width: var(--tap); padding: 0; }
  .memories p { font-size: 14px; color: var(--muted); overflow-wrap: anywhere; }
  .tag { font-size: 11px; text-transform: uppercase; color: var(--accent); margin-right: 6px; }
  .error { color: var(--bad); }
</style>
