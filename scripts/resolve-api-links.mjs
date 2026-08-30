#!/usr/bin/env node

import { readdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const siteRoot = resolve(process.argv[2] || join(projectRoot, "build/site"));
const indexPath = join(projectRoot, "docs/api/search-index.js");

if (!(await stat(siteRoot).catch(() => null))?.isDirectory()) {
  throw new Error(`site directory does not exist: ${siteRoot}`);
}

async function filesBelow(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const results = [];
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) results.push(...await filesBelow(path));
    else results.push(path);
  }
  return results;
}

const raw = await readFile(indexPath, "utf8");
const prefix = "window.FlyologyApiSearch = ";
if (!raw.startsWith(prefix) || !raw.trimEnd().endsWith(";")) {
  throw new Error("unexpected GNATdoc search-index.js format");
}

const entries = JSON.parse(raw.slice(prefix.length).trim().replace(/;$/, ""));
const candidatesByName = new Map();
for (const entry of entries) {
  if (entry.href.startsWith("/") || entry.href.split("/").includes("..")) {
    throw new Error(`unsafe GNATdoc target for ${entry.qualifiedName}: ${entry.href}`);
  }
  const candidates = candidatesByName.get(entry.qualifiedName) || [];
  candidates.push(entry);
  candidatesByName.set(entry.qualifiedName, candidates);
}

const pageCache = new Map();
async function declarationFor(entry) {
  if (entry.kind !== "Subprogram" || !entry.href.includes("#")) return "";
  const [pageName, fragment] = entry.href.split("#", 2);
  let page = pageCache.get(pageName);
  if (!page) {
    page = await readFile(join(siteRoot, "api", pageName), "utf8");
    pageCache.set(pageName, page);
  }
  const starts = [`id=${fragment}`, `id="${fragment}"`, `id='${fragment}'`]
    .map((needle) => page.indexOf(needle))
    .filter((index) => index >= 0);
  if (starts.length === 0) return "";
  const start = Math.min(...starts);
  const codeStart = page.indexOf("<code>", start);
  const codeEnd = page.indexOf("</code>", codeStart);
  if (codeStart < 0 || codeEnd < 0) return "";
  return page.slice(codeStart + 6, codeEnd)
    .replace(/<[^>]+>/g, " ")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&")
    .replace(/\s+/g, " ")
    .trim();
}

const declarations = new Map();
for (const candidates of candidatesByName.values()) {
  for (const entry of candidates) {
    const declaration = await declarationFor(entry);
    if (declaration !== "") declarations.set(entry.href, declaration);
  }
}

let resolvedCount = 0;
for (const file of (await filesBelow(siteRoot)).filter((path) => path.endsWith(".html"))) {
  let html = await readFile(file, "utf8");
  html = html.replace(/<a\s+data-api="([^"]+)"([^>]*)>/g, (_, name, rest) => {
    const signatureAttribute = rest.match(/\s+data-api-signature="([^"]+)"/);
    const signature = signatureAttribute?.[1];
    const candidates = candidatesByName.get(name) || [];
    let matches = candidates;

    if (signature) {
      matches = candidates.filter((entry) => declarations.get(entry.href)?.includes(signature));
      rest = rest.replace(/\s+data-api-signature="[^"]+"/, "");
    } else if (candidates.length > 1) {
      throw new Error(`ambiguous GNATdoc entity ${name} in ${file}; add data-api-signature`);
    }

    if (matches.length !== 1) {
      throw new Error(
        `expected one GNATdoc target for ${name}` +
          (signature ? ` containing ${signature}` : "") +
          `, found ${matches.length} in ${file}`,
      );
    }

    let href = relative(dirname(file), join(siteRoot, "api", matches[0].href));
    href = href.split(sep).join("/");
    resolvedCount += 1;
    return `<a href="${href}"${rest}>`;
  });
  if (html.includes("data-api=")) throw new Error(`unresolved data-api attribute in ${file}`);
  await writeFile(file, html);
}

console.log(`Resolved ${resolvedCount} authored API link(s).`);
