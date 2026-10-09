import { defineConfig } from "vitest/config";

// The suite runs against real Postgres and Redis: `npm run test:services` starts them locally
// (docker-compose.test.yml), CI uses service containers. Each test file gets its own Postgres schema
// and Redis key prefix (test/env.ts), so files run in parallel without seeing each other's rows.
export default defineConfig({
  test: {
    environment: "node",
    setupFiles: ["./test/setup.ts"],
    include: ["test/**/*.test.ts"],
    testTimeout: 30_000,
    hookTimeout: 60_000,
  },
});
