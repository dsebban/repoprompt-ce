<script lang="ts">
  import { app } from "../lib/app.svelte.ts";

  let token = $state("");
</script>

<form
  onsubmit={(e) => {
    e.preventDefault();
    if (token.trim()) app.setToken(token);
  }}
>
  <img src="/icon.svg" alt="" width="64" height="64" />
  <h1>Pi Overseer</h1>
  <p class="muted">Enter the phone token you set with <code>wrangler secret put PHONE_TOKEN</code>.</p>
  <input class="field" type="password" autocomplete="current-password" placeholder="Phone token" bind:value={token} />
  <button class="btn primary" disabled={!token.trim()}>Connect</button>
</form>

<style>
  form { margin: auto; width: min(100%, 420px); padding: 24px 16px; display: flex; flex-direction: column; gap: 12px; align-items: stretch; text-align: center; }
  img { align-self: center; border-radius: 16px; }
  h1 { margin: 0; font-size: 24px; }
  p { margin: 0; }
  button { padding: 12px; }
</style>
