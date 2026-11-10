import { realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { dirname } from "node:path";

// Loom runtime loader — the ONLY loader for the loom extension in this Pi
// process (loom is intentionally absent from settings.json `packages`).
//
// Why this exists: Pi runs on Node >= 23.6, where `.ts` files natively import.
// Pi's extension loader (jiti, tryNative default) therefore serves TS
// extension modules through Node's ESM module cache, which is keyed by URL and
// survives Pi's own `clearExtensionCache()`. A package-bound loom entry is
// cached forever, so `/reload` re-runs the STALE factory and the runtime
// revision handshake never refreshes — every engine source edit required a
// full Pi restart (proven empirically: reload with a mutated checkout left the
// old revision published).
//
// This loader imports loom's entry through a PRIVATE jiti configured with
// `tryNative: false` (jiti transforms and evaluates ALL modules itself) and
// `moduleCache: false` (no jiti module cache). Every load — startup and every
// `/reload` — re-evaluates loom's whole graph from current checkout bytes and
// re-publishes a fresh runtime revision, so the skew handshake stays honest
// and `/reload-runtime` (typed or tool-queued) suffices after source edits.
//
// Loom's skills/prompts are provided by its own `resources_discover` handler,
// so removing the package entry loses nothing. Update workflow: edit the loom
// checkout, run /reload-runtime, keep working. Restart Pi only for Pi itself.
//
// The loom root defaults to this machine's checkout and can be overridden with
// LOOM_RUNTIME_LOADER_ROOT. Load failures are fatal (rethrown) so a broken
// checkout surfaces at the point of failure instead of silently vanishing.
// Derive Pi's install dir from the running CLI (argv[1] = <pkg>/dist/cli.js) so
// the loader survives Nix store path changes on every pi rebuild/upgrade.
const PI_PACKAGE_ROOT = dirname(dirname(realpathSync(process.argv[1])));
const PI_DIST_INDEX = `${PI_PACKAGE_ROOT}/dist/index.js`;
const PI_NODE_MODULES = `${PI_PACKAGE_ROOT}/node_modules`;
const DEFAULT_LOOM_ROOT = `${homedir()}/dev/claude-plugins/loom`;

/** Load one Loom Pi entry (path relative to the Loom root) through the private jiti. */
export async function loadLoomExtension(pi: unknown, entryRelativePath: string): Promise<void> {
  const requireFromPi = createRequire(PI_DIST_INDEX);
  const { createJiti } = await import(`${PI_NODE_MODULES}/jiti/lib/jiti.mjs`);
  const jiti = createJiti(import.meta.url, {
    moduleCache: false,
    tryNative: false,
    alias: {
      typebox: requireFromPi.resolve("typebox"),
      "typebox/compile": requireFromPi.resolve("typebox/compile"),
      "typebox/value": requireFromPi.resolve("typebox/value"),
    },
  });
  const configuredRoot = process.env.LOOM_RUNTIME_LOADER_ROOT ?? DEFAULT_LOOM_ROOT;
  // LOOM_RUNTIME_LOADER_ROOT may name the checkout or (legacy) its main entry file.
  const loomRoot = configuredRoot.endsWith("/pi/extension.ts") ? configuredRoot.slice(0, -"/pi/extension.ts".length) : configuredRoot;
  const entry = `${loomRoot}/${entryRelativePath}`;
  const factory = (await jiti.import(entry, { default: true })) as (api: unknown) => Promise<void> | void;
  if (typeof factory !== "function") {
    throw new Error(`loom runtime loader: ${entry} does not export an extension factory`);
  }
  await factory(pi);
}

export default function loader(pi: unknown): Promise<void> {
  return loadLoomExtension(pi, "pi/extension.ts");
}
