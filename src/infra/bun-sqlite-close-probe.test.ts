import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createDeferredCore } from "../shared/deferred.js";
import { probeSqliteNativeClose } from "./bun-sqlite-close-probe.js";

vi.hoisted(() => vi.resetModules());

vi.mock("./runtime-process-entrypoints.js", () => ({
  runtimeProcessEntrypoints: { sqliteCloseProbe: {} },
}));
vi.mock("./runtime-worker-url.js", () => ({
  resolveRuntimeWorkerUrl: () => new URL("file:///fixture/sqlite-close-probe.js"),
}));

const state = vi.hoisted(() => {
  const workers: (EventEmitter & { terminate: ReturnType<typeof vi.fn> })[] = [];
  return {
    workers,
    join: Promise.resolve(1),
    remove: vi.fn(async () => {}),
  };
});
vi.mock("node:fs/promises", () => ({
  mkdtemp: async () => "/private/close-probe",
  realpath: async (path: string) => path,
  rm: state.remove,
}));
vi.mock("node:timers/promises", () => ({ setImmediate: async () => {} }));
vi.mock("node:worker_threads", () => ({
  Worker: class extends EventEmitter {
    terminate = vi.fn(() => state.join);
    constructor() {
      super();
      state.workers.push(this);
    }
  },
}));

beforeEach(() => {
  vi.useFakeTimers();
  state.workers.length = 0;
  state.join = Promise.resolve(1);
  state.remove.mockClear();
});
afterEach(() => vi.useRealTimers());

async function start() {
  const result = probeSqliteNativeClose();
  await vi.advanceTimersByTimeAsync(0);
  const worker = state.workers[0];
  assert(worker);
  return { worker, result };
}

it("joins the probe before deleting its private files or accepting success", async () => {
  const join = createDeferredCore<number>();
  state.join = join.promise;
  const { worker, result } = await start();
  worker.emit("message", "");
  await vi.advanceTimersByTimeAsync(0);
  expect(worker.terminate).toHaveBeenCalledOnce();
  expect(state.remove).not.toHaveBeenCalled();
  join.resolve(1);
  expect(await result).toMatchObject({ explicitSqliteCloseReleasesNativeResources: true });
  expect(state.remove).toHaveBeenCalledExactlyOnceWith("/private/close-probe", {
    recursive: true,
    force: true,
  });
  expect(vi.getTimerCount()).toBe(0);
});

it("times out conservatively and joins before cleanup", async () => {
  const { worker, result } = await start();
  await vi.advanceTimersByTimeAsync(10_000);
  expect(await result).toMatchObject({
    explicitSqliteCloseReleasesNativeResources: false,
    reason: expect.stringContaining("timed out"),
  });
  expect(worker.terminate).toHaveBeenCalledOnce();
  expect(state.remove).toHaveBeenCalledOnce();
});

it.each([
  ["error", new Error("native probe failed"), "native probe failed"],
  ["exit", 1, "exited before its reply"],
  ["message", undefined, "Invalid SQLite close probe reply"],
  ["message", "SQLite close probe cannot establish WAL mode", "WAL"],
] as const)(
  "records conservative %s failures and cleans up after joining",
  async (event, value, reason) => {
    const { worker, result } = await start();
    worker.emit(event, value);
    expect(await result).toMatchObject({
      explicitSqliteCloseReleasesNativeResources: false,
      reason: expect.stringContaining(reason),
    });
    expect(worker.terminate).toHaveBeenCalledOnce();
    expect(state.remove).toHaveBeenCalledOnce();
  },
);

it("retains files and refuses success when native termination fails", async () => {
  const { worker, result } = await start();
  worker.terminate.mockRejectedValueOnce(new Error("native join failed"));
  worker.emit("message", "");
  expect(await result).toMatchObject({
    explicitSqliteCloseReleasesNativeResources: false,
    reason: expect.stringContaining("native join failed"),
  });
  expect(state.remove).not.toHaveBeenCalled();
});
