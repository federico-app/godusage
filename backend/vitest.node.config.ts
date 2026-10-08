import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// The same suite on the Node server's runtime (server/): SQLite instead of D1, in-memory rate limits.
export default defineConfig({
  resolve: { alias: { "cloudflare:test": join(dirname(fileURLToPath(import.meta.url)), "test/node/cloudflareTest.ts") } },
  test: {
    environment: "node",
    setupFiles: ["./test/applyMigrations.ts"],
    include: ["test/**/*.test.ts"],
  },
});
