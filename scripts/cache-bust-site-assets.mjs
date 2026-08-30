#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, extname, join, relative, resolve, sep } from "node:path";

const requestedRoot = process.argv[2];
if (!requestedRoot) {
  console.error("usage: node scripts/cache-bust-site-assets.mjs <site-directory>");
  process.exit(2);
}

const root = resolve(requestedRoot);

async function walk(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(path));
    else files.push(path);
  }
  return files;
}

function insideRoot(path) {
  const fromRoot = relative(root, path);
  return fromRoot === "" || (!fromRoot.startsWith(`..${sep}`) && fromRoot !== "..");
}

const rootStat = await stat(root).catch(() => null);
if (!rootStat?.isDirectory()) throw new Error(`site directory does not exist: ${root}`);

const files = await walk(root);
const versionedAssets = new Map();
for (const path of files) {
  const fromRoot = relative(root, path);
  const extension = extname(path);
  if (
    !fromRoot.startsWith(`assets${sep}styles${sep}`) &&
    !fromRoot.startsWith(`assets${sep}scripts${sep}`)
  ) continue;
  if (extension !== ".css" && extension !== ".js") continue;
  const content = await readFile(path);
  const digest = createHash("sha256").update(content).digest("hex").slice(0, 12);
  versionedAssets.set(path, digest);
}

let rewrittenReferences = 0;
for (const htmlPath of files.filter((path) => path.endsWith(".html"))) {
  const html = await readFile(htmlPath, "utf8");
  const rewritten = html.replace(
    /(\s(?:href|src)=)(?:"([^"]+)"|'([^']+)'|([^\s>]+))/gi,
    (attribute, prefix, doubleQuoted, singleQuoted, unquoted) => {
      const reference = doubleQuoted || singleQuoted || unquoted;
      if (/^(?:[a-z]+:|\/\/)/i.test(reference)) return attribute;
      const hashIndex = reference.indexOf("#");
      const fragment = hashIndex >= 0 ? reference.slice(hashIndex) : "";
      const withoutFragment = hashIndex >= 0 ? reference.slice(0, hashIndex) : reference;
      const queryIndex = withoutFragment.indexOf("?");
      const rawPath = queryIndex >= 0 ? withoutFragment.slice(0, queryIndex) : withoutFragment;
      if (rawPath === "") return attribute;
      const assetPath = resolve(dirname(htmlPath), decodeURIComponent(rawPath));
      if (!insideRoot(assetPath)) return attribute;
      const digest = versionedAssets.get(assetPath);
      if (!digest) return attribute;
      const versionedReference = `${rawPath}?v=${digest}${fragment}`;
      rewrittenReferences += 1;
      if (doubleQuoted) return `${prefix}"${versionedReference}"`;
      if (singleQuoted) return `${prefix}'${versionedReference}'`;
      return `${prefix}${versionedReference}`;
    },
  );
  if (rewritten !== html) await writeFile(htmlPath, rewritten);
}

console.log(`Versioned ${versionedAssets.size} site assets across ${rewrittenReferences} HTML references.`);
