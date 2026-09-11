import { readFileSync, statSync } from "node:fs";
import pg from "pg";
import { CatalogStore, migrateCatalog } from "../../services/api/src/catalog/catalogStore.js";
import type { DisableCommand } from "../../services/api/src/catalog/types.js";

const [command, ...args] = process.argv.slice(2);
const databaseUrl = process.env.DATABASE_URL?.trim();
if (!databaseUrl || !["migrate", "import", "disable"].includes(command ?? "")) {
  console.error("Set DATABASE_URL. Usage: tsx tools/catalog-import/catalog.ts migrate | import <catalog.json> | disable <provider|intersection|approach> <key> <RIGHTS_UNVERIFIED|GEOMETRY_UNVERIFIED|SIGNAL_UNAVAILABLE|POLICY_DISABLED> <evidence>");
  process.exit(2);
}
const pool = new pg.Pool({ connectionString: databaseUrl, max: 1, connectionTimeoutMillis: 2000, query_timeout: 5000, statement_timeout: 5000 });
pool.on("error", () => { /* Command failure is reported without exposing connection details. */ });
try {
  if ((command === "migrate" && args.length !== 0) || (command === "import" && args.length !== 1) || (command === "disable" && args.length !== 4)) throw new Error("INVALID_ARGUMENTS");
  await migrateCatalog(pool);
  const store = new CatalogStore(pool);
  if (command === "migrate") {
    console.log(JSON.stringify({ migrated: true }));
  } else if (command === "import") {
    const path = args[0]!;
    if (statSync(path).size > 10 * 1024 * 1024) throw new Error("CATALOG_TOO_LARGE");
    const document: unknown = JSON.parse(readFileSync(path, "utf8"));
    const result = await store.publish(document);
    console.log(JSON.stringify(result));
    if (!result.published) process.exitCode = 1;
  } else {
    // The store validates the complete command at its public boundary.
    const [scope, key, reason, evidence] = args;
    const result = await store.disable({ scope, key, reason, evidence } as DisableCommand);
    console.log(JSON.stringify(result));
    if (!result.disabled) process.exitCode = 1;
  }
} catch {
  console.error(JSON.stringify({ error: "CATALOG_COMMAND_FAILED", message: "Check command arguments, catalog JSON, database availability and migration permissions. Connection details are not logged." }));
  process.exitCode = 1;
} finally {
  await pool.end();
}
