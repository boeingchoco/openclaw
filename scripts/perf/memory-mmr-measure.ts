// node --expose-gc --import ./scripts/tsx.mjs scripts/perf/memory-mmr-measure.ts
// Run each workload in a fresh process; alternate --owner baseline/candidate externally.
// --mode counts instruments candidate visits and fixture-token membership; timings use neither hook.
import assert from "node:assert/strict";
import { hash } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import { parseStrictIntegerOption } from "../lib/strict-integer-option.ts";

const { values } = parseArgs({
  options: {
    owner: { type: "string", default: "extensions/memory-core/src/memory/hybrid.ts" },
    workload: { type: "string", default: "duplicate-heavy" },
    mode: { type: "string", default: "timing" },
    samples: { type: "string", default: "20" },
    warmup: { type: "string", default: "10" },
  },
});
assert.ok(
  ["duplicate-heavy", "mixed", "distinct", "overlapping", "near-duplicate"].includes(
    values.workload,
  ),
);
assert.ok(["timing", "counts"].includes(values.mode));
const samples = parseStrictIntegerOption({
  raw: values.samples,
  label: "--samples",
  min: 1,
  fallback: 20,
});
const warmup = parseStrictIntegerOption({
  raw: values.warmup,
  label: "--warmup",
  min: 0,
  fallback: 10,
});
const owner: typeof import("../../extensions/memory-core/src/memory/hybrid.js") = await import(
  pathToFileURL(path.resolve(values.owner)).href
);
const sharedTokens =
  values.workload === "overlapping" ? 20 : values.workload === "near-duplicate" ? 79 : 0;
const rows = Array.from({ length: 400 }, (_row, index) => {
  // Mixed: 300 entries across 10 duplicate groups, plus 100 distinct entries.
  const group =
    values.workload === "duplicate-heavy"
      ? 0
      : values.workload === "mixed" && index < 300
        ? index % 10
        : index;
  const snippet = Array.from({ length: 80 }, (_token, token) =>
    token < sharedTokens ? `c${token}` : `m${group}_${token}`,
  ).join(" ");
  assert.ok(snippet.length <= 700, "Fixture must fit the retrieval snippet limit");
  return {
    id: `candidate-${index}`,
    path: `memory/candidate-${String(index).padStart(3, "0")}.md`,
    startLine: 1,
    endLine: 5,
    source: "memory",
    snippet,
  };
});
const vector = rows
  .slice(0, 200)
  .map((row, index) => Object.assign({}, row, { vectorScore: 0.9 - (index % 10) * 0.01 }));
const keyword = rows
  .slice(200)
  .map((row, index) => Object.assign({}, row, { textScore: 0.9 - (index % 10) * 0.01 }));
const inputJson = JSON.stringify({ vector, keyword });
async function run() {
  const merged = await owner.mergeHybridResults({
    vector,
    keyword,
    vectorWeight: 0.7,
    textWeight: 0.3,
    mmr: { enabled: true, lambda: 0.7 },
    temporalDecay: { enabled: false, halfLifeDays: 30 },
  });
  const selected = owner.selectHybridSearchResults({
    merged,
    keyword,
    vectorCandidates: vector,
    maxResults: 200,
    minScore: 0.35,
  });
  return { merged, selected };
}
function fingerprint(result: Awaited<ReturnType<typeof run>>) {
  assert.equal(result.merged.length, 400);
  assert.equal(result.selected.length, 200);
  assert.equal(JSON.stringify({ vector, keyword }), inputJson, "Input mutated");
  // Both complete order/scores and the selected public results participate.
  return hash("sha256", JSON.stringify(result), "hex");
}
const metadata = {
  owner: path.resolve(values.owner),
  workload: values.workload,
  mode: values.mode,
  node: process.version,
  cpu: os.cpus()[0]?.model,
  load: os.loadavg(),
  candidates: rows.length,
  tokensPerSnippet: 80,
};
if (values.mode === "counts") {
  // oxlint-disable-next-line typescript/unbound-method -- Forward the original receiver below.
  const original = Set.prototype.has;
  const originalIterator = Set.prototype[Symbol.iterator];
  let tokenMemberships = 0;
  let candidateVisits = 0;
  let result: Awaited<ReturnType<typeof run>>;
  try {
    // oxlint-disable-next-line eslint/no-extend-native -- Count without retaining mock call history; restored in finally.
    Set.prototype.has = function (this: Set<unknown>, value: unknown) {
      // Only Jaccard sees these token keys; hybrid range/project keys differ.
      if (typeof value === "string" && /^(?:m\d+_\d+|c\d+)$/u.test(value)) {
        tokenMemberships++;
      }
      return original.call(this, value);
    };
    // oxlint-disable-next-line eslint/no-extend-native -- Count actual candidate visits without retaining elements; restored in finally.
    Set.prototype[Symbol.iterator] = function* (this: Set<unknown>): SetIterator<unknown> {
      const iterator: SetIterator<unknown> = originalIterator.call(this);
      for (const value of iterator) {
        // Only the MMR candidate set contains prepared relevance and similarity.
        if (
          value &&
          typeof value === "object" &&
          "maxSimilarity" in value &&
          "relevance" in value
        ) {
          candidateVisits++;
        }
        yield value;
      }
      return undefined;
    };
    result = await run();
  } finally {
    // oxlint-disable-next-line eslint/no-extend-native -- Restore the original method after count-only instrumentation.
    Set.prototype.has = original;
    // oxlint-disable-next-line eslint/no-extend-native -- Restore iteration after count-only instrumentation.
    Set.prototype[Symbol.iterator] = originalIterator;
  }
  console.log(
    JSON.stringify({
      ...metadata,
      candidateVisits,
      tokenMemberships,
      fingerprint: fingerprint(result),
    }),
  );
} else {
  assert.ok(global.gc, "Timing mode requires --expose-gc");
  const gc = global.gc;
  async function measure() {
    const cpu = process.cpuUsage();
    const start = performance.now();
    const result = await run();
    const ms = performance.now() - start;
    const used = process.cpuUsage(cpu);
    return { ms, cpuMs: (used.user + used.system) / 1000, fingerprint: fingerprint(result) };
  }
  gc();
  const cold = await measure();
  for (let index = 0; index < warmup; index++) {
    await run();
  }
  gc();
  const heapBefore = process.memoryUsage().heapUsed;
  const warm: { ms: number; cpuMs: number; fingerprint: string }[] = [];
  for (let index = 0; index < samples; index++) {
    const sample = await measure();
    assert.equal(sample.fingerprint, cold.fingerprint, "Ranking changed between runs");
    warm.push(sample);
  }
  gc();
  const retainedHeapDeltaBytes = process.memoryUsage().heapUsed - heapBefore;
  console.log(JSON.stringify({ ...metadata, warmup, cold, warm, retainedHeapDeltaBytes }));
}
