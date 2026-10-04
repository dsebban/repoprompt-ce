<script lang="ts">
  import { app, type Tab } from "../lib/app.svelte.ts";

  const tabs: { id: Tab; label: string; icon: string }[] = [
    { id: "chat", label: "Chat", icon: "M4 5h16v11H8l-4 4z" },
    { id: "sessions", label: "Sessions", icon: "M4 6h16M4 12h16M4 18h10" },
    { id: "workspaces", label: "Workspaces", icon: "M3 7h7l2 2h9v10H3z" },
    { id: "memory", label: "Memory", icon: "M12 3a6 6 0 0 1 6 6c0 3-2 4-2 7H8c0-3-2-4-2-7a6 6 0 0 1 6-6zM9 20h6" },
  ];

  function select(tab: Tab) {
    app.tab = tab;
    if (tab === "memory") app.unseenActivity = 0;
  }
</script>

<nav>
  {#each tabs as t (t.id)}
    <button class:active={app.tab === t.id} onclick={() => select(t.id)} aria-current={app.tab === t.id ? "page" : undefined}>
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d={t.icon} /></svg>
      <span>{t.label}</span>
      {#if t.id === "memory" && app.unseenActivity > 0}<b>{app.unseenActivity}</b>{/if}
    </button>
  {/each}
</nav>

<style>
  nav {
    display: grid; grid-template-columns: repeat(4, 1fr);
    border-top: 1px solid var(--line); background: var(--bg);
    padding-bottom: env(safe-area-inset-bottom);
  }
  button { position: relative; border: 0; background: none; padding: 8px 0 6px; display: flex; flex-direction: column; align-items: center; gap: 2px; color: var(--muted); font-size: 11px; }
  button.active { color: var(--accent); }
  svg { width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
  b { position: absolute; top: 4px; left: calc(50% + 6px); background: var(--bad); color: #fff; font-size: 10px; border-radius: 999px; padding: 0 5px; }
</style>
