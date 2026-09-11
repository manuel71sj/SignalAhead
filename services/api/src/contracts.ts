import { existsSync, readFileSync } from "node:fs";
import { Ajv2020 } from "ajv/dist/2020.js";

function schema(name: string): object {
  const sourcePath = new URL(`../../../contracts/${name}.schema.json`, import.meta.url);
  const compiledPath = new URL(`../../../../contracts/${name}.schema.json`, import.meta.url);
  return JSON.parse(readFileSync(existsSync(sourcePath) ? sourcePath : compiledPath, "utf8")) as object;
}

const ajv = new Ajv2020({ allErrors: true, strict: false });
export const catalogSchema = schema("catalog");
export const validateCatalogShape = ajv.compile(catalogSchema);
const signalSchema = schema("signal");
ajv.addSchema(signalSchema);
export const validateSignalShape = ajv.compile({ $ref: "https://signalahead.local/contracts/signal.schema.json#/$defs/SignalObservation" });
export const validateReplayShape = ajv.compile(schema("replay"));
