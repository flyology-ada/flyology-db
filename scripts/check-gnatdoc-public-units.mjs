#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";

if (process.argv.length !== 4) {
  console.error("usage: node scripts/check-gnatdoc-public-units.mjs <api-directory> <expected-units>");
  process.exit(2);
}

const [apiArgument, expectedArgument] = process.argv.slice(2);
const apiRoot = resolve(apiArgument);
const indexSource = await readFile(join(apiRoot, "search-index.js"), "utf8");
const expectedSource = await readFile(resolve(expectedArgument), "utf8");
const prefix = "window.FlyologyApiSearch = ";

if (!indexSource.startsWith(prefix) || !indexSource.trimEnd().endsWith(";")) {
  throw new Error("unexpected GNATdoc search-index.js format");
}

const entries = JSON.parse(indexSource.slice(prefix.length).trim().replace(/;$/, ""));
if (entries.length === 0) throw new Error("GNATdoc search index is empty");

const actual = entries
  .filter((entry) => entry.kind === "Compilation unit")
  .map((entry) => entry.qualifiedName)
  .sort();
const expected = expectedSource
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter((line) => line !== "" && !line.startsWith("#"))
  .sort();

if (new Set(actual).size !== actual.length) {
  throw new Error("GNATdoc search index contains duplicate compilation units");
}

if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  console.error("Generated public compilation units differ from the reviewed set.");
  console.error("Expected:");
  for (const name of expected) console.error("  " + name);
  console.error("Actual:");
  for (const name of actual) console.error("  " + name);
  process.exit(1);
}

console.log(`GNATdoc public unit set matches exactly: ${actual.length} unit(s).`);
