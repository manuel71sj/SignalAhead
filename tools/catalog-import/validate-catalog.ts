import { readFileSync, statSync } from "node:fs";
import { validateCatalogForPublication } from "../../services/api/src/catalog/validateCatalog.js";
import { validateReplayShape } from "../../services/api/src/contracts.js";

const [input, flag, ...extra] = process.argv.slice(2);
if (input === undefined || (flag !== undefined && flag !== "--synthetic-verification") || extra.length !== 0) {
  console.error("usage: tsx tools/catalog-import/validate-catalog.ts <catalog-or-replay-json> [--synthetic-verification]");
  process.exit(2);
}
try {
  if (statSync(input).size > 10 * 1024 * 1024) throw new Error("CATALOG_TOO_LARGE");
  let document: unknown = JSON.parse(readFileSync(input, "utf8"));
  if (typeof document === "object" && document !== null && "catalog" in document) {
    if (!validateReplayShape(document)) throw new Error("INVALID_REPLAY_SCHEMA");
    document = document.catalog;
  }
  const result = validateCatalogForPublication(document, flag === "--synthetic-verification" ? "synthetic-verification" : "operational");
  console.log(JSON.stringify(result, null, 2));
  process.exitCode = result.valid ? 0 : 1;
} catch {
  console.error(JSON.stringify({ valid: false, error: "INVALID_CATALOG_DOCUMENT" }));
  process.exitCode = 1;
}
