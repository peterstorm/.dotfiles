// An arm: one model, reached the way cortex would reach it.
//
//   direct:<provider>/<model>[+unguided]   cortex's OpenAI-compatible client (llm-client.ts),
//                                           endpoint and key from the Pi provider config
//   claude:<model>                          `claude -p --model <model>` (cortex's default subprocess)
//   pi:<provider>/<model>                   `pi -p --provider … --model …` (cortex under a Pi session)
//
// `+unguided` drops the job's JSON schema / JSON mode from direct requests, to
// see the format discipline a provider without guided decoding would get. The
// answer is still parsed strictly, as production parses every direct answer.

import { type Result, err, ok } from './model.ts';

export type Decoding = 'guided' | 'unguided';

export type Arm = Readonly<
  | { kind: 'direct'; id: string; provider: string; model: string; decoding: Decoding }
  | { kind: 'claude'; id: string; model: string }
  | { kind: 'pi'; id: string; provider: string; model: string }
>;

export type ArmError = Readonly<{ kind: 'bad-arm'; spec: string; expected: string }>;

const EXPECTED = 'direct:<provider>/<model>[+unguided] | claude:<model> | pi:<provider>/<model>';

/** provider/model, where the model id may itself contain slashes (`Qwen/Qwen3-8B`). */
const providerModel = (rest: string): readonly [string, string] | undefined => {
  const slash = rest.indexOf('/');
  if (slash <= 0 || slash === rest.length - 1) return undefined;
  return [rest.slice(0, slash), rest.slice(slash + 1)];
};

export const parseArm = (spec: string): Result<Arm, ArmError> => {
  const bad = err({ kind: 'bad-arm', spec, expected: EXPECTED } as const);
  const colon = spec.indexOf(':');
  if (colon <= 0) return bad;
  const kind = spec.slice(0, colon);
  const rest = spec.slice(colon + 1);
  // `kind` is free text from the command line, an open domain: unknown kinds fall through to `bad`.
  if (kind === 'direct') {
    const unguided = rest.endsWith('+unguided');
    const pm = providerModel(unguided ? rest.slice(0, -'+unguided'.length) : rest);
    if (pm === undefined) return bad;
    return ok({ kind: 'direct', id: spec, provider: pm[0], model: pm[1], decoding: unguided ? 'unguided' : 'guided' });
  }
  if (kind === 'claude') {
    return rest.length > 0 && !rest.includes('/') ? ok({ kind: 'claude', id: spec, model: rest }) : bad;
  }
  if (kind === 'pi') {
    const pm = providerModel(rest);
    return pm === undefined ? bad : ok({ kind: 'pi', id: spec, provider: pm[0], model: pm[1] });
  }
  return bad;
};

/** A file-name-safe form of the arm id. Injective on the ids parseArm accepts: `%` escapes are reversible. */
export const armSlug = (arm: Arm): string => arm.id.replace(/[^A-Za-z0-9._+-]/g, (c) => `%${c.charCodeAt(0).toString(16).padStart(2, '0')}`);
