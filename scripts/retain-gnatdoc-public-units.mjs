#!/usr/bin/env node

import { readdir, readFile, unlink, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";

if (process.argv.length !== 4) {
  console.error(
    "usage: node scripts/retain-gnatdoc-public-units.mjs " +
      "<api-directory> <public-units>",
  );
  process.exit(2);
}

const apiRoot = resolve(process.argv[2]);
const publicSource = await readFile(resolve(process.argv[3]), "utf8");
const publicUnits = new Set(
  publicSource
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line !== "" && !line.startsWith("#")),
);
const indexPath = join(apiRoot, "index.html");
let index = await readFile(indexPath, "utf8");
const items = [...index.matchAll(
  /<li><a\s+href=(?:"([^"#]+\.html)"|'([^'#]+\.html)'|([^\s>#]+\.html))[^>]*>([^<]+)<\/a>/g,
)];
const foundPublic = new Set();
const retainedPages = new Set();
const removedPages = new Set();

for (const item of items) {
  const name = item[1] || item[2] || item[3];
  const label = item[4].trim();
  if (basename(name) !== name) throw new Error(`unsafe generated unit page path: ${name}`);
  if (publicUnits.has(label)) {
    if (foundPublic.has(label)) throw new Error(`duplicate generated public unit ${label}`);
    foundPublic.add(label);
    retainedPages.add(name);
    continue;
  }
  index = index.replace(item[0], "");
  removedPages.add(name);
}

for (const unit of publicUnits) {
  if (!foundPublic.has(unit)) throw new Error(`GNATdoc did not generate public unit ${unit}`);
}

let removed = 0;
for (const name of await readdir(apiRoot)) {
  if (!name.endsWith(".html") || name === "index.html" || retainedPages.has(name)) continue;
  if (basename(name) !== name) throw new Error(`unsafe generated unit page path: ${name}`);
  await unlink(join(apiRoot, name));
  removed += 1;
}

await writeFile(indexPath, index);
console.log(
  `Retained ${publicUnits.size} reviewed public unit page(s); removed ${removed} other page(s).`,
);
