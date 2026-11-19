// The retrospective's vocabulary. A Run is one scheduled reclaw skill execution
// recovered from a Pi session file; everything downstream reads only these types.

export type Result<T, E> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: E };

export const ok = <T>(value: T): Result<T, never> => ({ ok: true, value });
export const err = <E>(error: E): Result<never, E> => ({ ok: false, error });

export const assertNever = (x: never): never => {
  throw new Error(`unreachable: ${JSON.stringify(x)}`);
};

/** A reclaw skill's id: its YAML file name without the extension. */
export type SkillId = string & { readonly __brand: 'SkillId' };
export const SkillId = (s: string): SkillId => s as SkillId;

/**
 * Which side of the local-vs-cloud question a model sits on. Local means it
 * was served by the workstation (`desktop-vllm`, `llama.cpp`), whatever the
 * weights; everything else is a hosted provider.
 */
export type ModelClass = 'local' | 'cloud';

export type ModelRef = Readonly<{ provider: string; model: string; class: ModelClass }>;

const LOCAL_PROVIDERS: ReadonlySet<string> = new Set(['desktop-vllm', 'desktop-muse', 'llama.cpp']);

export const modelRef = (provider: string, model: string): ModelRef => ({
  provider,
  model,
  class: LOCAL_PROVIDERS.has(provider) ? 'local' : 'cloud',
});

export const modelKey = (m: ModelRef): string => `${m.provider}/${m.model}`;

/** What the model asked a tool to do, reduced to the fields the graders read. */
export type ToolCall =
  | Readonly<{ kind: 'bash'; command: string }>
  | Readonly<{ kind: 'write'; path: string; content: string }>
  | Readonly<{ kind: 'edit'; path: string }>
  | Readonly<{ kind: 'read'; path: string }>
  | Readonly<{ kind: 'other'; name: string }>;

/** Why a run delivered nothing. Mirrors reclaw's runner: any provider error fails the run. */
export type FailureReason =
  | Readonly<{ kind: 'provider-error'; message: string }>
  | Readonly<{ kind: 'aborted' }>
  | Readonly<{ kind: 'no-text' }>;

/**
 * What reclaw did with the run. `delivered` text is exactly what reached
 * Telegram: the last text-bearing assistant message (pi-backend parseResult).
 */
export type RunOutcome =
  | Readonly<{ kind: 'delivered'; text: string; truncated: boolean }>
  | Readonly<{ kind: 'all-clear' }>
  | Readonly<{ kind: 'failed'; reason: FailureReason }>;

export type TokenUsage = Readonly<{ input: number; output: number; reasoning: number }>;

export type Run = Readonly<{
  sessionId: string;
  file: string;
  startedAt: Date;
  endedAt: Date;
  /** The scheduled prompt: the session's first user message. */
  prompt: string;
  /** The model that produced the run's last assistant message. */
  model: ModelRef;
  /** True when more than one model answered inside the scheduled segment. */
  mixedModels: boolean;
  thinkingLevel: string | null;
  toolCalls: readonly ToolCall[];
  /**
   * What the model could legitimately quote, besides its prompt: every tool
   * result's text and every context block the harness injected (the cortex
   * memory surface arrives as a custom message).
   */
  evidence: readonly string[];
  outcome: RunOutcome;
  usage: TokenUsage;
}>;

export const durationMs = (run: Run): number => run.endedAt.getTime() - run.startedAt.getTime();
