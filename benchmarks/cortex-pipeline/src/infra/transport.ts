// An arm's transport, built from cortex's own clients.
//
// Direct arms call cortex's chatCompletion: the same thinking switches,
// reasoning-effort bounds for GLM, answer budgets and error naming production
// uses. CLI arms call cortex's runLlmPrompt with the CORTEX_LLM_* variables
// production reads. What the benchmark deliberately leaves out is
// runLlmPromptDirect's fallback: a failed direct call is a failure of the arm,
// not a reason to try a different model.

import type { Arm } from '../domain/arm.ts';
import type { ArmTransport, RequestOptions } from '../domain/port.ts';
import { type Result, assertNever, err, ok } from '../domain/model.ts';
import { type CortexModule, parseCompletion } from './cortex.ts';

export type TransportError = Readonly<{ kind: 'no-endpoint'; provider: string }>;

const elapsed = (started: number): number => Math.round(performance.now() - started);

/** Unguided: keep the answer budget, drop the schema and JSON mode the job asked for. */
const unguided = (options: RequestOptions | undefined): RequestOptions =>
  options?.maxTokens === undefined ? {} : { maxTokens: options.maxTokens };

/**
 * The transport for an arm. CLI arms configure cortex through the environment
 * it reads at call time, so a process runs one CLI arm at a time.
 */
export const armTransport = (arm: Arm, cortex: CortexModule): Result<ArmTransport, TransportError> => {
  switch (arm.kind) {
    case 'direct': {
      process.env.CORTEX_LLM_PROVIDER = arm.provider;
      const endpoint = cortex.resolveOpenAiCompatEndpoint();
      if (endpoint === null) return err({ kind: 'no-endpoint', provider: arm.provider });
      const target = { ...endpoint, model: arm.model };
      return ok(async (prompt, timeoutMs, options) => {
        const started = performance.now();
        const sent = arm.decoding === 'guided' ? (options ?? {}) : unguided(options);
        const reply = parseCompletion(await cortex.chatCompletion(target, prompt, { ...sent, timeoutMs }));
        return {
          text: reply.content,
          direct: true,
          meta: {
            latencyMs: elapsed(started),
            servedModel: reply.model,
            promptTokens: reply.promptTokens,
            completionTokens: reply.completionTokens,
          },
        };
      });
    }
    case 'claude':
    case 'pi': {
      process.env.CORTEX_LLM_BINARY = arm.kind;
      process.env.CORTEX_LLM_MODEL = arm.model;
      if (arm.kind === 'pi') process.env.CORTEX_LLM_PROVIDER = arm.provider;
      else delete process.env.CORTEX_LLM_PROVIDER;
      return ok(async (prompt, timeoutMs) => {
        const started = performance.now();
        // 'off', as production's subprocess path sends without a direct endpoint;
        // cortex itself raises it to 'low' for models that refuse 'off'.
        const text = await cortex.runLlmPrompt(prompt, timeoutMs, 'off');
        return {
          text,
          direct: false,
          meta: { latencyMs: elapsed(started), servedModel: null, promptTokens: null, completionTokens: null },
        };
      });
    }
    default:
      return assertNever(arm);
  }
};
