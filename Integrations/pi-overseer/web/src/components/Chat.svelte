<script lang="ts">
  import { tick } from "svelte";
  import { app } from "../lib/app.svelte.ts";
  import { renderMarkdown } from "../lib/parse.ts";

  const quick = [
    ["Status", "What's running and what's waiting on me?"],
    ["Needs me", "Which sessions need my input? Show the pending question or approval for each."],
    ["Overseer digest", "Ask the overseer for a digest of all its lanes."],
    ["While away", "What happened while I was away?"],
  ] as const;

  let text = $state("");
  let scroller: HTMLDivElement;
  let input: HTMLTextAreaElement;
  let pinned = true; // stick to the bottom unless the user scrolled up

  function onScroll() {
    pinned = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 80;
  }

  // Re-runs only when the item count or the live text changes.
  $effect(() => {
    void app.items.length;
    void app.live;
    if (pinned) void tick().then(() => scroller?.scrollTo({ top: scroller.scrollHeight }));
  });

  function submit(e?: Event) {
    e?.preventDefault();
    if (!text.trim()) return;
    app.send(text);
    text = "";
    pinned = true;
    input.style.height = "";
  }

  function grow() {
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, 140)}px`;
  }

  const desktop = typeof window !== "undefined" && !("ontouchstart" in window);
</script>

<div class="scroll log" bind:this={scroller} onscroll={onScroll}>
  {#if app.items.length === 0 && !app.live}
    <p class="empty muted">Ask about your sessions, start work, or say “set up the overseer”.</p>
  {/if}
  {#each app.items as item (item.id)}
    {#if item.kind === "user"}
      <div class="bubble user">{item.text}</div>
    {:else if item.kind === "assistant"}
      <div class="bubble md">{@html renderMarkdown(item.text)}</div>
    {:else if item.kind === "tool"}
      <div class="note">→ {item.text}</div>
    {:else}
      <div class="note" class:error={item.kind === "error"}>{item.text}</div>
    {/if}
  {/each}
  {#if app.live}
    <div class="bubble live">{app.live}</div>
  {/if}
</div>

<div class="chips">
  {#each quick as [label, prompt] (label)}
    <button class="btn" onclick={() => app.send(prompt)}>{label}</button>
  {/each}
  {#if app.streaming}<button class="btn danger" onclick={() => app.abort()}>Stop</button>{/if}
</div>

<form onsubmit={submit}>
  <textarea
    bind:this={input}
    bind:value={text}
    oninput={grow}
    onkeydown={(e) => desktop && e.key === "Enter" && !e.shiftKey && submit(e)}
    rows="1"
    placeholder="Tell Pi what to do…"
    enterkeyhint="send"
  ></textarea>
  <button class="btn primary" disabled={!text.trim()} aria-label="Send">Send</button>
</form>

<style>
  .log { padding: 12px var(--gutter-r) 12px var(--gutter-l); display: flex; flex-direction: column; gap: 8px; }
  .empty { text-align: center; margin: auto; max-width: 260px; }
  .bubble {
    max-width: 88%; padding: 8px 12px; border-radius: var(--radius); background: var(--card);
    border: 1px solid var(--line); overflow-wrap: anywhere;
  }
  .bubble.user { align-self: flex-end; white-space: pre-wrap; background: var(--me); color: var(--accent-fg); border-color: transparent; }
  .bubble.live { white-space: pre-wrap; }
  .note { align-self: center; font-size: 12px; color: var(--muted); text-align: center; max-width: 95%; }
  .note.error { color: var(--bad); }
  .chips { display: flex; gap: 6px; overflow-x: auto; padding: 8px var(--gutter-r) 0 var(--gutter-l); scrollbar-width: none; flex: none; }
  .chips::-webkit-scrollbar { display: none; }
  form { display: flex; gap: 8px; padding: 8px var(--gutter-r) 8px var(--gutter-l); align-items: flex-end; flex: none; }
  textarea { flex: 1; resize: none; border: 1px solid var(--line); border-radius: 22px; padding: 10px 16px; min-height: var(--tap); background: var(--card); max-height: 140px; }
  form .btn { border-radius: 22px; }
</style>
