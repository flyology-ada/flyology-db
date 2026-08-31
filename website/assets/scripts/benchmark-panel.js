(function () {
  "use strict";

  const engineLabels = {
    "tidesdb-full-sync": "TidesDB · full sync",
    "slatedb-default": "SlateDB · 100 ms default",
    "slatedb-1ms": "SlateDB · 1 ms",
    "slatedb-rustfs-default": "SlateDB · 100 ms default",
    "slatedb-rustfs-1ms": "SlateDB · 1 ms",
  };
  const seriesClasses = new Map([
    ["tidesdb-full-sync", "series-tides"],
    ["slatedb-default", "series-slate-default"],
    ["slatedb-1ms", "series-slate-fast"],
    ["slatedb-rustfs-default", "series-slate-default"],
    ["slatedb-rustfs-1ms", "series-slate-fast"],
  ]);
  const localAxes = {
    key: ["key-8", "baseline", "key-64", "key-256"],
    value: ["value-64", "baseline", "value-16384", "value-65536"],
    batch: ["baseline", "batch-16", "batch-64", "batch-256"],
    sustained: ["sustained-8960"],
  };
  const remoteAxis = ["baseline", "value-16384", "batch-16", "sustained-8960"];
  const workloadLabels = {
    baseline: "1 × 1 KiB",
    "key-8": "8 B key",
    "key-64": "64 B key",
    "key-256": "256 B key",
    "value-64": "64 B value",
    "value-16384": "16 KiB value",
    "value-65536": "64 KiB value",
    "batch-16": "16 mutations",
    "batch-64": "64 mutations",
    "batch-256": "256 mutations",
    "sustained-8960": "8,960 objects",
  };

  function element(name, className, text) {
    const node = document.createElement(name);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function ratio(record) {
    const selected = record.primary;
    return selected.contender_median / selected.reference_median;
  }

  function formatNumber(value, digits = 2) {
    return new Intl.NumberFormat("en-US", {
      maximumFractionDigits: digits,
      minimumFractionDigits: value < 10 ? Math.min(2, digits) : 0,
    }).format(value);
  }

  function formatDuration(nanoseconds) {
    if (nanoseconds < 1_000) return `${formatNumber(nanoseconds, 0)} ns`;
    if (nanoseconds < 1_000_000) return `${formatNumber(nanoseconds / 1_000)} µs`;
    if (nanoseconds < 1_000_000_000) return `${formatNumber(nanoseconds / 1_000_000)} ms`;
    return `${formatNumber(nanoseconds / 1_000_000_000)} s`;
  }

  function ratioStatement(record) {
    const value = ratio(record);
    if (value >= 1) {
      return `${engineLabels[record.contender]} took ${formatNumber(value)} times as long as Flyology.DB`;
    }
    return `Flyology.DB took ${formatNumber(1 / value)} times as long as ${engineLabels[record.contender]}`;
  }

  function recordsFor(state, data) {
    const artifact = data.artifacts[state.lane];
    const order = state.lane === "local" ? localAxes[state.axis] : remoteAxis;
    return artifact.records
      .filter((record) => order.includes(record.workload.id))
      .sort((left, right) => {
        const workload = order.indexOf(left.workload.id) - order.indexOf(right.workload.id);
        if (workload !== 0) return workload;
        return left.contender.localeCompare(right.contender);
      });
  }

  function renderSummary(records, state, root) {
    root.replaceChildren();
    const ordered = records.slice().sort((left, right) => ratio(right) - ratio(left));
    const largestFlyology = ordered[0];
    const largestContender = ordered[ordered.length - 1];
    const contenderWins = records.filter((record) => ratio(record) < 1).length;
    const cards = [
      {
        label: "Largest ratio above 1×",
        value: `${formatNumber(ratio(largestFlyology))}×`,
        detail: `${workloadLabels[largestFlyology.workload.id]} vs ${engineLabels[largestFlyology.contender]}`,
      },
      {
        label: "Largest ratio below 1×",
        value: ratio(largestContender) < 1
          ? `${formatNumber(1 / ratio(largestContender))}×`
          : "none",
        detail: ratio(largestContender) < 1
          ? `${workloadLabels[largestContender.workload.id]} · ${engineLabels[largestContender.contender]}`
          : "Flyology.DB has lower time in this filtered view",
      },
      {
        label: "Lower median primary latency",
        value: `${records.length - contenderWins} / ${contenderWins}`,
        detail: "lower Flyology.DB time / lower contender time",
      },
    ];
    for (const card of cards) {
      const item = element("div", "benchmark-summary-card");
      item.append(
        element("span", "benchmark-summary-label", card.label),
        element("strong", "benchmark-summary-value", card.value),
        element("span", "benchmark-summary-detail", card.detail),
      );
      root.append(item);
    }
  }

  function svgElement(name, attributes = {}) {
    const node = document.createElementNS("http://www.w3.org/2000/svg", name);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    return node;
  }

  function renderChart(records, state, root, legend, status) {
    root.replaceChildren();
    legend.replaceChildren();
    const workloads = [...new Set(records.map((record) => record.workload.id))];
    const contenders = [...new Set(records.map((record) => record.contender))];
    const width = 960;
    const height = 430;
    const margin = { top: 24, right: 32, bottom: 78, left: 78 };
    const chartWidth = width - margin.left - margin.right;
    const chartHeight = height - margin.top - margin.bottom;
    const minimum = 0.03;
    const maximum = 100;
    const logarithm = (value) => Math.log10(value);
    const y = (value) => margin.top + chartHeight
      - ((logarithm(value) - logarithm(minimum))
        / (logarithm(maximum) - logarithm(minimum))) * chartHeight;
    const x = (index) => margin.left
      + (workloads.length === 1 ? chartWidth / 2 : index * chartWidth / (workloads.length - 1));
    const svg = svgElement("svg", {
      class: "benchmark-chart",
      viewBox: `0 0 ${width} ${height}`,
      role: "img",
      "aria-label": "Pairwise time ratio chart. Values above one favor Flyology.DB; values below one favor the contender.",
    });

    for (const tick of [0.03, 0.1, 0.3, 1, 3, 10, 30, 100]) {
      const line = svgElement("line", {
        x1: margin.left,
        x2: width - margin.right,
        y1: y(tick),
        y2: y(tick),
        class: tick === 1 ? "benchmark-parity-line" : "benchmark-grid-line",
      });
      const label = svgElement("text", {
        x: margin.left - 14,
        y: y(tick) + 4,
        class: "benchmark-axis-label",
        "text-anchor": "end",
      });
      label.textContent = `${tick}×`;
      svg.append(line, label);
    }

    workloads.forEach((workload, index) => {
      const label = svgElement("text", {
        x: x(index),
        y: height - 32,
        class: "benchmark-axis-label",
        "text-anchor": "middle",
      });
      label.textContent = workloadLabels[workload];
      svg.append(label);
    });

    for (const contender of contenders) {
      const contenderRecords = workloads
        .map((workload) => records.find(
          (record) => record.workload.id === workload && record.contender === contender,
        ))
        .filter(Boolean);
      const className = seriesClasses.get(contender);
      if (contenderRecords.length > 1) {
        svg.append(svgElement("polyline", {
          points: contenderRecords.map((record) => {
            const index = workloads.indexOf(record.workload.id);
            return `${x(index)},${y(Math.max(minimum, Math.min(maximum, ratio(record))))}`;
          }).join(" "),
          class: `benchmark-series-line ${className}`,
        }));
      }
      for (const record of contenderRecords) {
        const index = workloads.indexOf(record.workload.id);
        const point = svgElement("circle", {
          cx: x(index),
          cy: y(Math.max(minimum, Math.min(maximum, ratio(record)))),
          r: 6,
          class: `benchmark-series-point ${className}`,
        });
        const title = svgElement("title");
        title.textContent = `${engineLabels[contender]}, ${workloadLabels[record.workload.id]}: ${ratioStatement(record)}`;
        point.append(title);
        svg.append(point);
      }
      const legendItem = element("span", `benchmark-legend-item ${className}`);
      legendItem.append(element("i", "", ""), document.createTextNode(engineLabels[contender]));
      legend.append(legendItem);
    }
    root.append(svg);
    status.textContent = `Showing ${records.length} paired comparisons. Above 1× means Flyology.DB has lower median primary latency.`;
  }

  function renderTable(records, state, body) {
    body.replaceChildren();
    for (const record of records) {
      const selected = record.primary;
      const value = ratio(record);
      const row = document.createElement("tr");
      const cells = [
        workloadLabels[record.workload.id],
        engineLabels[record.contender],
        formatDuration(selected.reference_median),
        formatDuration(selected.contender_median),
        ratioStatement(record),
        `${formatNumber(selected.interval_low_percent)}% to ${formatNumber(selected.interval_high_percent)}%`,
        `${record.samples} pairs · ${record.order.reference_first}/${record.order.contender_first} order`,
      ];
      cells.forEach((text, index) => {
        const cell = element(index === 0 ? "th" : "td", "", text);
        if (index === 0) cell.scope = "row";
        if (index === 4) cell.className = value >= 1 ? "ratio-flyology" : "ratio-contender";
        row.append(cell);
      });
      body.append(row);
    }
  }

  function escapeHtml(value) {
    return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  }

  function highlightRust(code) {
    const keywords = new Set(
      "as async await break const continue crate else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"
        .split(" "),
    );
    const pattern = /\/\/[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])+'|\b\d[\d_]*\b|\b[A-Za-z_][A-Za-z0-9_]*\b/g;
    const source = code.textContent;
    let result = "";
    let previous = 0;
    source.replace(pattern, function (token, offset) {
      let className = "";
      if (token.startsWith("//")) className = "token-comment";
      else if (token.startsWith('"') || token.startsWith("'")) className = "token-string";
      else if (/^\d/.test(token)) className = "token-number";
      else if (keywords.has(token)) className = "token-keyword";
      result += escapeHtml(source.slice(previous, offset));
      result += className
        ? `<span class="${className}">${escapeHtml(token)}</span>`
        : escapeHtml(token);
      previous = offset + token.length;
      return token;
    });
    code.innerHTML = result + escapeHtml(source.slice(previous));
  }

  function populateSources(data) {
    document.querySelectorAll("[data-benchmark-source]").forEach(function (code) {
      const source = data.sources[code.dataset.benchmarkSource];
      if (!source) return;
      code.textContent = source.code;
      code.dataset.sourcePath = source.path;
      code.dataset.sourceRegion = source.region;
      const metadata = code.closest("details")?.querySelector("[data-benchmark-source-meta]");
      if (metadata) {
        metadata.textContent = `${source.path} · ${source.region} · excerpt sha256:${source.sha256}`;
      }
      if (source.language === "ada") window.FlyologyAda.highlight(code);
      else highlightRust(code);
    });
  }

  document.addEventListener("DOMContentLoaded", async function () {
    const panel = document.querySelector("[data-benchmark-panel]");
    if (!panel) return;
    const state = { lane: "local", axis: "key" };
    const status = panel.querySelector("[data-benchmark-status]");
    try {
      const response = await fetch(panel.dataset.benchmarkData, { cache: "no-store" });
      if (!response.ok) throw new Error(`benchmark data returned HTTP ${response.status}`);
      const data = await response.json();
      if (data.schema_version !== "flyology.db.benchmark.site.v1") {
        throw new Error("benchmark data schema is unsupported");
      }
      populateSources(data);
      document.querySelectorAll("[data-artifact-hash]").forEach(function (node) {
        node.textContent = data.artifacts[node.dataset.artifactHash].sha256;
      });
      document.querySelectorAll("[data-artifact-provenance]").forEach(function (node) {
        const artifact = data.artifacts[node.dataset.artifactProvenance];
        const provenance = artifact.provenance;
        node.textContent = `repository ${provenance.repository_commit}; `
          + `panel ${provenance.panel_adapter_sha256}; `
          + `executable ${provenance.panel_executable_sha256}; `
          + `driver ${provenance.campaign_driver_sha256}`;
      });
      const summary = panel.querySelector("[data-benchmark-summary]");
      const chart = panel.querySelector("[data-benchmark-chart]");
      const legend = panel.querySelector("[data-benchmark-legend]");
      const tableBody = panel.querySelector("[data-benchmark-table-body]");
      const referenceHeader = panel.querySelector("[data-reference-header]");
      const contenderHeader = panel.querySelector("[data-contender-header]");
      const caption = panel.querySelector("[data-benchmark-caption]");

      function selectButtons(attribute, value) {
        panel.querySelectorAll(`[${attribute}]`).forEach(function (button) {
          button.setAttribute("aria-pressed", String(button.getAttribute(attribute) === value));
        });
      }

      function render() {
        panel.querySelectorAll("[data-local-axis]").forEach(function (button) {
          button.hidden = state.lane !== "local";
        });
        panel.querySelector("[data-remote-axis]").hidden = state.lane !== "rustfs";
        const records = recordsFor(state, data);
        renderSummary(records, state, summary);
        renderChart(records, state, chart, legend, status);
        renderTable(records, state, tableBody);
        referenceHeader.textContent = "Flyology.DB time";
        contenderHeader.textContent = "Contender time";
        caption.textContent = `${state.lane === "local" ? "Local Files lane" : "RustFS lane"} · `
          + `${state.axis === "remote" ? "selected remote workloads" : state.axis === "sustained" ? "sustained workload" : `${state.axis}-size workloads`} · `
          + "median primary latency from 10 paired samples";
        selectButtons("data-lane", state.lane);
        selectButtons("data-axis", state.axis);
      }

      panel.addEventListener("click", function (event) {
        const button = event.target.closest("button");
        if (!button) return;
        if (button.dataset.lane) {
          state.lane = button.dataset.lane;
          state.axis = state.lane === "local" ? "key" : "remote";
        }
        if (button.dataset.axis) state.axis = button.dataset.axis;
        render();
      });
      render();
    } catch (error) {
      status.textContent = `Benchmark data is unavailable: ${error.message}`;
      panel.dataset.failed = "true";
      document.querySelectorAll("[data-benchmark-source]").forEach(function (code) {
        code.textContent = "Exact source excerpt is unavailable. Use the current-source link below.";
      });
    }
  });
})();
