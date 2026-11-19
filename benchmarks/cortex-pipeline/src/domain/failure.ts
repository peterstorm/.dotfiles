// Why a call produced no usable answer, from the error text cortex's transports
// throw. The classes are the failure modes the local-model history showed:
// thinking that never stops (reasoning-only, truncated), a box that is off
// (network), a slow prefill (timeout), and a provider that refuses (refused).

export const FAILURE_CLASSES = [
  'network',
  'timeout',
  'truncated',
  'reasoning-only',
  'empty',
  'refused',
  'server-error',
  'cli-exit',
  'unparseable',
  'corrupt',
  'other',
] as const;
export type FailureClass = (typeof FAILURE_CLASSES)[number];

const RULES: ReadonlyArray<readonly [FailureClass, RegExp]> = [
  ['reasoning-only', /only reasoning_content/],
  ['truncated', /truncated|finish_reason=length/],
  ['timeout', /timed out after/],
  ['empty', /empty content|Empty response/i],
  ['refused', /LLM API 4\d\d|quota|rate.?limit|usage limit|weekly limit/i],
  ['server-error', /LLM API 5\d\d/],
  ['network', /fetch failed|ECONNREFUSED|ECONNRESET|EHOSTUNREACH|Unable to connect|ConnectionRefused|socket/i],
  ['cli-exit', /exited with code|CLI not found/],
];

/** The class of a transport error. First matching rule wins; the order puts the specific before the generic. */
export const classifyTransportError = (message: string): FailureClass =>
  RULES.find(([, pattern]) => pattern.test(message))?.[0] ?? 'other';
