#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";

const repositoryRoot = resolve(import.meta.dirname, "..");
const siteRoot = resolve(process.argv[2] || join(repositoryRoot, "build/site"));
const resultsRoot = join(repositoryRoot, "benchmarks/comparison/results");

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function canonicalJson(value, numbersAsFloat = false) {
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("non-finite number in benchmark evidence");
    return numbersAsFloat && Number.isInteger(value) ? `${value}.0` : JSON.stringify(value);
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalJson(item, numbersAsFloat)).join(",")}]`;
  }
  return `{${Object.keys(value).sort().map(
    (key) => `${JSON.stringify(key)}:${canonicalJson(value[key], numbersAsFloat)}`,
  ).join(",")}}`;
}

function jsonSha256(value, numbersAsFloat = false) {
  return sha256(canonicalJson(value, numbersAsFloat));
}

async function readJson(path) {
  return JSON.parse(await readFile(path, "utf8"));
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function parseNdjson(bytes, label) {
  const records = bytes.toString("utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
  if (records.length === 0) throw new Error(`empty benchmark metrics: ${label}`);
  return records;
}

function insideRepository(path) {
  const fromRoot = relative(repositoryRoot, path);
  return fromRoot !== ".." && !fromRoot.startsWith(`..${sep}`);
}

async function extractRegion(pathFromRoot, region, markerPrefix, language) {
  const path = resolve(repositoryRoot, pathFromRoot);
  if (!insideRepository(path)) throw new Error(`source escapes repository: ${pathFromRoot}`);
  const source = (await readFile(path, "utf8")).replaceAll("\r\n", "\n");
  const lines = source.split("\n");
  const start = `${markerPrefix} website-benchmark:start ${region}`;
  const end = `${markerPrefix} website-benchmark:end ${region}`;
  const starts = lines.flatMap((line, index) => line.trimStart() === start ? [index] : []);
  const ends = lines.flatMap((line, index) => line.trimStart() === end ? [index] : []);
  if (starts.length !== 1 || ends.length !== 1 || starts[0] >= ends[0]) {
    throw new Error(`benchmark region ${region} is not unique and ordered in ${pathFromRoot}`);
  }
  const code = lines.slice(starts[0] + 1, ends[0]).join("\n");
  return { path: pathFromRoot, region, language, code, sha256: sha256(code) };
}

function summarizeMetric(metric) {
  if (!metric?.available || metric.status !== "collected") {
    throw new Error(`required metric ${metric?.axis || "unknown"} is unavailable`);
  }
  return {
    axis: metric.axis,
    unit: metric.unit,
    scope: metric.scope,
    timing_source: metric.timing_source,
    reference_median: metric.reference_median,
    contender_median: metric.contender_median,
    change_percent: metric.change,
    interval_low_percent: metric.interval_low,
    interval_high_percent: metric.interval_high,
    verdict: metric.verdict,
  };
}

async function loadArtifact(filename, lane, expectedRecords) {
  const path = join(resultsRoot, filename);
  const bytes = await readFile(path);
  const artifact = JSON.parse(bytes);
  const rawRoot = join(resultsRoot, `${filename.slice(0, -5)}-raw`);
  const campaign = await readJson(join(rawRoot, "campaign.json"));
  if (
    campaign.schema_version !== "flyology.db.benchmark.campaign.v1"
    || campaign.identity?.lane !== lane
    || artifact.schema_version !== "flyology.db.benchmark.matrix.v3"
    || artifact.lane !== lane
    || artifact.records.length !== expectedRecords
    || artifact.campaign_identity_sha256 !== campaign.identity_sha256
    || campaign.identity_sha256 !== jsonSha256(campaign.identity)
    || !sameJson(artifact.host, campaign.identity.host)
    || !sameJson(artifact.method, campaign.identity.method)
    || !sameJson(artifact.provenance, campaign.identity.provenance)
  ) {
    throw new Error(`unexpected benchmark artifact identity: ${filename}`);
  }

  const expectedRecordsById = new Map();
  for (const workload of campaign.identity.plan.workloads) {
    for (const [reference, contender] of campaign.identity.plan.pairs) {
      const id = `${lane}--${workload.id}--${reference}--${contender}`;
      expectedRecordsById.set(id, { workload, reference, contender });
    }
  }
  if (expectedRecordsById.size !== expectedRecords) {
    throw new Error(`unexpected benchmark campaign matrix: ${filename}`);
  }

  const records = [];
  for (const record of artifact.records) {
    const requestName = `${record.lane}--${record.workload.id}--${record.reference}--${record.contender}`;
    const expectedRecord = expectedRecordsById.get(requestName);
    const comparisonPath = resolve(rawRoot, record.raw.comparison);
    const metricsPath = resolve(rawRoot, record.raw.metrics);
    const requestPath = join(rawRoot, `${requestName}.request.json`);
    const sealPath = join(rawRoot, `${requestName}.seal.json`);
    if (
      !expectedRecord
      || !insideRepository(comparisonPath)
      || !insideRepository(metricsPath)
      || dirname(comparisonPath) !== rawRoot
      || dirname(metricsPath) !== rawRoot
      || !sameJson(record.workload, expectedRecord.workload)
      || record.reference !== expectedRecord.reference
      || record.contender !== expectedRecord.contender
    ) {
      throw new Error(`benchmark record escapes or differs from campaign plan: ${requestName}`);
    }
    expectedRecordsById.delete(requestName);
    const comparisonBytes = await readFile(comparisonPath);
    const metricsBytes = await readFile(metricsPath);
    const requestBytes = await readFile(requestPath);
    const sealBytes = await readFile(sealPath);
    const request = JSON.parse(requestBytes);
    const seal = JSON.parse(sealBytes);
    const rawComparison = JSON.parse(comparisonBytes);
    const rawMetrics = parseNdjson(metricsBytes, requestName);
    if (
      sha256(comparisonBytes) !== record.raw.comparison_sha256
      || sha256(metricsBytes) !== record.raw.metrics_sha256
      || sha256(requestBytes) !== record.request_sha256
      || sha256(sealBytes) !== record.seal_sha256
      || request.schema_version !== "flyology.db.benchmark.pair-request.v1"
      || request.campaign_identity_sha256 !== campaign.identity_sha256
      || request.identity !== requestName
      || request.reference !== record.reference
      || request.contender !== record.contender
      || !sameJson(request.workload, record.workload)
      || seal.schema_version !== "flyology.db.benchmark.pair-seal.v1"
      || seal.request_sha256 !== sha256(requestBytes)
      || seal.comparison_sha256 !== sha256(comparisonBytes)
      || seal.metrics_sha256 !== sha256(metricsBytes)
      || rawComparison.type !== "comparison"
      || rawComparison.reference !== record.reference
      || rawComparison.contender !== record.contender
      || !sameJson(rawComparison, record.comparison)
      || !sameJson(rawMetrics, record.metrics)
      || record.comparison.samples !== 10
      || record.comparison.reference_first !== 5
      || record.comparison.contender_first !== 5
    ) {
      throw new Error(`unsealed or unbalanced benchmark pair: ${requestName}`);
    }
    const primary = record.metrics.find(
      (metric) => metric.kind === "custom" && metric.axis === "primary_time",
    );
    const primaryMetrics = record.metrics.filter(
      (metric) => metric.kind === "custom" && metric.axis === "primary_time",
    );
    if (
      primaryMetrics.length !== 1
      || primary.reference !== record.reference
      || primary.contender !== record.contender
      || seal.primary_metric_sha256 !== jsonSha256(primary, true)
    ) {
      throw new Error(`benchmark primary metric is not uniquely sealed: ${requestName}`);
    }
    records.push({
      id: requestName,
      lane: record.lane,
      workload: record.workload,
      reference: record.reference,
      contender: record.contender,
      samples: record.comparison.samples,
      order: {
        reference_first: record.comparison.reference_first,
        contender_first: record.comparison.contender_first,
        effect_percent: record.comparison.order_effect_percent,
      },
      primary: summarizeMetric(primary),
    });
  }
  if (expectedRecordsById.size !== 0) {
    throw new Error(`benchmark campaign matrix is incomplete: ${filename}`);
  }

  return {
    path: `benchmarks/comparison/results/${filename}`,
    sha256: sha256(bytes),
    campaign_identity_sha256: artifact.campaign_identity_sha256,
    host: artifact.host,
    method: artifact.method,
    provenance: artifact.provenance,
    remote_server: campaign.identity.remote_server,
    records,
  };
}

const local = await loadArtifact("publishable-local.json", "local", 33);
const rustfs = await loadArtifact("publishable-rustfs-v2.json", "rustfs", 8);
const sources = {
  flyology: await extractRegion(
    "benchmarks/comparison/src/flyology_db_benchmark_flyology.adb",
    "flyology-durable-transaction",
    "-- ",
    "ada",
  ),
  tidesdb: await extractRegion(
    "benchmarks/comparison/src/flyology_db_benchmark_tidesdb.adb",
    "tidesdb-durable-transaction",
    "-- ",
    "ada",
  ),
  slatedb: await extractRegion(
    "benchmarks/comparison/slatedb/src/lib.rs",
    "slatedb-durable-transaction",
    "//",
    "rust",
  ),
};

const output = {
  schema_version: "flyology.db.benchmark.site.v1",
  classification: "directional",
  artifacts: { local, rustfs },
  sources,
};
const outputPath = join(siteRoot, "assets/data/benchmark-matrix.json");
await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, `${JSON.stringify(output)}\n`);
console.log(`Built benchmark site data at ${outputPath} (${local.records.length + rustfs.records.length} pairs).`);
