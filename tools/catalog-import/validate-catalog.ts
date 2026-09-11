import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { validateCatalogForPublication } from "../../services/api/src/catalog/validateCatalog.js";
import type { ApproachCatalog } from "../../services/api/src/catalog/types.js";

function catalogFromDocument(document: unknown): ApproachCatalog {
  if (typeof document !== "object" || document === null || !("catalog" in document)) {
    return document as ApproachCatalog;
  }
  return document.catalog as ApproachCatalog;
}

const input = process.argv[2];
if (input === undefined) {
  console.error("usage: tsx tools/catalog-import/validate-catalog.ts <catalog-or-replay-json>");
  process.exit(2);
}

const document = JSON.parse(readFileSync(resolve(input), "utf8")) as unknown;
const result = validateCatalogForPublication(catalogFromDocument(document));
console.log(JSON.stringify(result, null, 2));
process.exit(result.valid ? 0 : 1);
