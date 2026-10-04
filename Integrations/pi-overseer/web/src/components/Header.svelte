<script lang="ts">
  import { app } from "../lib/app.svelte.ts";
</script>

<header>
  <strong>Pi Overseer</strong>
  {#if app.streaming}<span class="working" aria-live="polite">working…</span>{/if}
  <span class="pill" title={app.bridge ? "Mac bridge connected" : "Mac bridge offline"}>
    <i class="dot {app.bridge ? 'tone-ok' : 'tone-bad'}"></i>Mac
  </span>
  {#if !app.online}<span class="pill"><i class="dot tone-wait"></i>reconnecting</span>{/if}
</header>

<style>
  header {
    display: flex; align-items: center; gap: 10px;
    padding: calc(10px + env(safe-area-inset-top)) 16px 10px;
    border-bottom: 1px solid var(--line); background: var(--bg);
  }
  strong { margin-right: auto; font-size: 17px; }
  .pill { display: inline-flex; align-items: center; gap: 5px; font-size: 13px; color: var(--muted); }
  .working { font-size: 13px; color: var(--accent); }
</style>
