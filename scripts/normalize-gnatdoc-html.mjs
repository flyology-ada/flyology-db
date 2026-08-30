#!/usr/bin/env node

import { access, readdir, readFile, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";

if (process.argv.length !== 3) {
  console.error("usage: node scripts/normalize-gnatdoc-html.mjs <api-directory>");
  process.exit(2);
}

const root = resolve(process.argv[2]);
const files = (await readdir(root)).filter((name) => name.endsWith(".html"));
if (files.length === 0) throw new Error("GNATdoc generated no HTML pages");

const anchors = new Map();
for (const name of files) {
  const html = await readFile(join(root, name), "utf8");
  for (const match of html.matchAll(/\sid=(?:"([0-9a-f]{64})"|([0-9a-f]{64}))(?:\s|>)/g)) {
    anchors.set(match[1] || match[2], name);
  }
}

for (const name of files) {
  const path = join(root, name);
  let html = await readFile(path, "utf8");
  html = html.replace(
    "<html class=main>",
    '<html lang="en" class=main><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>',
  );
  for (const match of [...html.matchAll(/href=(?:"([0-9a-f]{64}\.html)"|([0-9a-f]{64}\.html))/g)]) {
    const reference = match[1] || match[2];
    const digest = reference.slice(0, 64);
    try {
      await access(join(root, reference));
    } catch {
      const owner = anchors.get(digest);
      if (!owner) throw new Error(`${basename(path)} has unresolved GNATdoc target ${digest}`);
      html = html.replaceAll(`href=${reference}`, `href=${owner}#${digest}`);
      html = html.replaceAll(`href="${reference}"`, `href="${owner}#${digest}"`);
    }
  }
  await writeFile(path, html);
}
