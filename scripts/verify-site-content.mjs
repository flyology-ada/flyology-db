#!/usr/bin/env node

import { readFile, readdir, stat } from "node:fs/promises";
import { join, resolve } from "node:path";

const siteRoot = resolve(process.argv[2]);
const repositoryRoot = process.cwd();
const cname = (await readFile(join(siteRoot, "CNAME"), "utf8")).trim();
const llms = await readFile(join(siteRoot, "llms.txt"), "utf8");
const supportHtml = await readFile(join(siteRoot, "support/index.html"), "utf8");
const support = supportHtml
  .replace(/<script\b[\s\S]*?<\/script>/gi, " ")
  .replace(/<style\b[\s\S]*?<\/style>/gi, " ")
  .replace(/<[^>]+>/g, " ")
  .replace(/\s+/g, " ");

if (cname !== "db.flyology.org") throw new Error(`unexpected CNAME: ${cname}`);

const routes = [
  "/",
  "/guide/",
  "/guide/getting-started/",
  "/guide/checkpoint-and-reopen/",
  "/guide/families-and-maintenance/",
  "/guide/certainty-and-authority/",
  "/guide/storage-limits-and-ownership/",
  "/architecture/",
  "/support/",
  "/api/",
];
for (const route of routes) {
  if (!llms.includes(`(${route})`)) throw new Error(`llms.txt does not list ${route}`);
  const target = route === "/" ? join(siteRoot, "index.html") : join(siteRoot, route, "index.html");
  if (!(await stat(target).catch(() => null))?.isFile()) {
    throw new Error(`llms.txt route has no built page: ${route}`);
  }
}

const boundaryPhrases = [
  "experimental",
  "0.1.0-dev",
  "object storage",
  "one fenced writer",
  "same identity",
  "no automatic maintenance",
  "no production qualification",
  "Outcome_Unknown",
  "inside Commit",
];
for (const phrase of boundaryPhrases) {
  if (!llms.toLowerCase().includes(phrase.toLowerCase())) {
    throw new Error(`llms.txt omits boundary phrase: ${phrase}`);
  }
  if (!support.toLowerCase().includes(phrase.toLowerCase())) {
    throw new Error(`support page omits boundary phrase: ${phrase}`);
  }
}

async function htmlFilesUnder(directory) {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) result.push(...await htmlFilesUnder(path));
    else if (entry.isFile() && entry.name.endsWith(".html")) result.push(path);
  }
  return result;
}

function decodeHtml(value) {
  const named = new Map([
    ["amp", "&"],
    ["apos", "'"],
    ["gt", ">"],
    ["lt", "<"],
    ["quot", "\""],
  ]);
  return value.replace(/&(#x[0-9a-f]+|#[0-9]+|amp|apos|gt|lt|quot);/gi, (_, entity) => {
    if (entity.startsWith("#x")) return String.fromCodePoint(Number.parseInt(entity.slice(2), 16));
    if (entity.startsWith("#")) return String.fromCodePoint(Number.parseInt(entity.slice(1), 10));
    return named.get(entity.toLowerCase());
  });
}

let exampleCount = 0;
for (const htmlPath of await htmlFilesUnder(siteRoot)) {
  const html = await readFile(htmlPath, "utf8");
  for (const match of html.matchAll(/<code\b([^>]*)>([\s\S]*?)<\/code>/g)) {
    const sourceAttribute = match[1].match(/\bdata-example-source="([^"]+)"/);
    const regionAttribute = match[1].match(/\bdata-example-region="([^"]+)"/);
    if (!sourceAttribute && !regionAttribute) continue;
    if (!sourceAttribute || !regionAttribute) {
      throw new Error(`incomplete executable-example attributes in ${htmlPath}`);
    }

    const sourcePath = resolve(repositoryRoot, sourceAttribute[1]);
    if (!sourcePath.startsWith(`${repositoryRoot}/`)) {
      throw new Error(`example source escapes repository: ${sourceAttribute[1]}`);
    }
    const source = (await readFile(sourcePath, "utf8")).replaceAll("\r\n", "\n");
    const lines = source.split("\n");
    const region = regionAttribute[1];
    const startMarker = `--  website-example:start ${region}`;
    const endMarker = `--  website-example:end ${region}`;
    const starts = lines.flatMap((line, index) => line.trimStart() === startMarker ? [index] : []);
    const ends = lines.flatMap((line, index) => line.trimStart() === endMarker ? [index] : []);
    if (starts.length !== 1 || ends.length !== 1 || starts[0] >= ends[0]) {
      throw new Error(`example region ${region} is not unique and ordered in ${sourceAttribute[1]}`);
    }

    const expected = lines.slice(starts[0] + 1, ends[0]).join("\n");
    const actual = decodeHtml(match[2]);
    if (actual !== expected) {
      throw new Error(`example region ${region} differs from ${sourceAttribute[1]}`);
    }
    exampleCount += 1;
  }
}

if (exampleCount === 0) throw new Error("site contains no maintained executable Ada example regions");

console.log(`Verified db.flyology.org routes and ${boundaryPhrases.length} support boundaries.`);
console.log(`Verified ${exampleCount} maintained executable Ada example region(s).`);
