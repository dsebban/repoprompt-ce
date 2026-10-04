<script lang="ts">
  import { onMount } from "svelte";
  import { app } from "./lib/app.svelte.ts";
  import Login from "./components/Login.svelte";
  import Header from "./components/Header.svelte";
  import TabBar from "./components/TabBar.svelte";
  import Chat from "./components/Chat.svelte";
  import Sessions from "./components/Sessions.svelte";
  import Workspaces from "./components/Workspaces.svelte";
  import Memory from "./components/Memory.svelte";

  onMount(() => {
    void app.start().catch(() => {});
    const onVisibility = () => document.visibilityState === "visible" && app.onVisible();
    document.addEventListener("visibilitychange", onVisibility);
    return () => document.removeEventListener("visibilitychange", onVisibility);
  });
</script>

{#if !app.token}
  <Login />
{:else}
  <Header />
  <main>
    {#if app.tab === "chat"}
      <Chat />
    {:else if app.tab === "sessions"}
      <Sessions />
    {:else if app.tab === "workspaces"}
      <Workspaces />
    {:else}
      <Memory />
    {/if}
  </main>
  <TabBar />
{/if}

<style>
  main { flex: 1; min-height: 0; display: flex; flex-direction: column; }
</style>
