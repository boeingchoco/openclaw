import { describe, expect, it, vi } from "vitest";
import {
  runEmbeddedAgentMock,
  setupAgentRunnerTestHooks,
} from "./agent-runner.misc.runreplyagent.test-support.js";
import { createBaseRun } from "./agent-runner.runreplyagent.test-support.js";

const sanitizerState = vi.hoisted(() => ({
  sanitizeUserFacingText: vi.fn(),
}));

vi.mock("../../agents/embedded-agent-helpers/sanitize-user-facing-text.js", async () => {
  const actual = await vi.importActual<
    typeof import("../../agents/embedded-agent-helpers/sanitize-user-facing-text.js")
  >("../../agents/embedded-agent-helpers/sanitize-user-facing-text.js");
  sanitizerState.sanitizeUserFacingText.mockImplementation(actual.sanitizeUserFacingText);
  return {
    ...actual,
    sanitizeUserFacingText: (...args: Parameters<typeof actual.sanitizeUserFacingText>) =>
      sanitizerState.sanitizeUserFacingText(...args),
  };
});

await vi.hoisted(async () => {
  await import("./agent-runner.misc.runreplyagent.test-support.js");
});

await import("./agent-runner-run.js");

setupAgentRunnerTestHooks();

describe("runReplyAgent lazy partial text", () => {
  it("stops sanitizing visible partials once one has content", async () => {
    let partialSanitizes: number | undefined;
    runEmbeddedAgentMock.mockImplementationOnce(
      async (params: { onPartialReply?: (payload: { text: string }) => Promise<unknown> }) => {
        const before = sanitizerState.sanitizeUserFacingText.mock.calls.length;
        for (const text of ["first", "first second", "first second third"]) {
          await params.onPartialReply?.({ text });
        }
        partialSanitizes = sanitizerState.sanitizeUserFacingText.mock.calls.length - before;
        return {
          payloads: [{ text: "first second third" }],
          meta: { agentMeta: { usage: { input: 1, output: 1 } } },
        };
      },
    );
    // A Telegram-style preview reports every partial visible and reads text only at flush.
    const onPartialReply = vi.fn(async () => true);

    const { run } = createBaseRun({ reply: { opts: { onPartialReply } } });
    await run();

    expect(onPartialReply).toHaveBeenCalledTimes(3);
    expect(partialSanitizes).toBe(1);
  });
});
