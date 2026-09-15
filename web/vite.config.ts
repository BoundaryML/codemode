import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The TS frontend talks to the BAML HTTP server. /api is proxied for curl-style
// calls; /ws is the live event channel (proxied as a WebSocket).
// CODEMODE_API=http://127.0.0.1:8788 pnpm dev   → point at another BAML server.
const api = process.env.CODEMODE_API ?? "http://127.0.0.1:8787";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": { target: api, changeOrigin: true },
      "/ws": { target: api.replace(/^http/, "ws"), ws: true },
    },
  },
});
