import { svelte } from "@sveltejs/vite-plugin-svelte";
import { defineConfig } from "vite";

// `npm run dev` proxies the API and sockets to a local `wrangler dev` on :8787.
export default defineConfig({
  plugins: [svelte()],
  build: { target: "es2022", cssCodeSplit: false, modulePreload: false, reportCompressedSize: true },
  server: {
    proxy: {
      "/api": "http://127.0.0.1:8787",
      "/phone": { target: "ws://127.0.0.1:8787", ws: true },
    },
  },
});
