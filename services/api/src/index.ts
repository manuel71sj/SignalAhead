import { buildApp } from "./app.js";
import { loadConfig } from "./config.js";

const config = loadConfig();
const app = buildApp({ config });

const shutdown = () => { void app.close().catch(() => { process.exitCode = 1; }); };
process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);

try {
  await app.listen({ host: "0.0.0.0", port: config.port });
} catch {
  console.error("API startup failed; check port and runtime configuration.");
  await app.close();
  process.exitCode = 1;
}
