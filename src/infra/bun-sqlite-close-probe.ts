import { channel } from "node:diagnostics_channel";
import { mkdtemp, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setImmediate as nextTurn } from "node:timers/promises";
import { Worker } from "node:worker_threads";
import { runtimeProcessEntrypoints } from "./runtime-process-entrypoints.js";
import { resolveRuntimeWorkerUrl } from "./runtime-worker-url.js";

type SqliteCloseProbeResult = Readonly<{
  explicitSqliteCloseReleasesNativeResources: boolean;
  reason: string;
}>;

export async function probeSqliteNativeClose(): Promise<SqliteCloseProbeResult> {
  let directory: string | undefined;
  let worker: Worker | undefined;
  let deadline: NodeJS.Timeout | undefined;
  let result: SqliteCloseProbeResult;
  try {
    directory = await realpath(await mkdtemp(join(tmpdir(), "openclaw-sqlite-close-")));
    channel("openclaw.sqlite.close-probe").publish({ phase: "start" });
    worker = new Worker(resolveRuntimeWorkerUrl(runtimeProcessEntrypoints.sqliteCloseProbe), {
      workerData: directory,
      execArgv: [],
    });
    const running = worker;
    result = await new Promise<SqliteCloseProbeResult>((resolve, reject) => {
      running.once("message", (value: unknown) => {
        if (typeof value !== "string") {
          reject(new Error("Invalid SQLite close probe reply"));
          return;
        }
        resolve({
          explicitSqliteCloseReleasesNativeResources: value === "",
          reason: value || "Native close probe passed",
        });
      });
      running.once("error", reject);
      running.once("exit", (code) =>
        reject(new Error(`SQLite close probe exited before its reply (${code})`)),
      );
      deadline = setTimeout(
        () => reject(new Error("SQLite close probe timed out after 10000ms")),
        10_000,
      );
    });
  } catch (error) {
    result = { explicitSqliteCloseReleasesNativeResources: false, reason: String(error) };
  } finally {
    clearTimeout(deadline);
    try {
      if (worker) {
        await worker.terminate();
        await nextTurn();
      }
      // A failed native join retains custody of the private directory.
      if (directory) {
        await rm(directory, { recursive: true, force: true });
      }
    } catch (error) {
      result = {
        explicitSqliteCloseReleasesNativeResources: false,
        reason: `SQLite close probe cleanup failed: ${String(error)}`,
      };
    }
  }
  return result;
}
