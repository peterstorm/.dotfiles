/**
 * Loom Rules Gate — thin shim. The gate itself (requirements, full-read
 * coverage, adherence marker, block text) lives in the Loom checkout and is
 * shared with the Claude Code hook:
 *   core    loom/engine/src/core/rules-gate.ts        (the one decision)
 *   Pi      loom/pi/rules-gate.ts                     (context entries → events)
 *   Claude  loom/engine/src/handlers/pre-tool-use/rules-gate.ts
 * It is loaded through the same private jiti as the main loom extension, so
 * `/reload-runtime` picks up edits to the checkout. Escape hatches
 * (LOOM_GATE=off, LOOM_GATE_MODES, LOOM_RULES_DIR) are documented in
 * loom/docs/operations.md.
 */
import { loadLoomExtension } from "./loom-runtime-loader";

export default function (pi: unknown): Promise<void> {
  return loadLoomExtension(pi, "pi/rules-gate.ts");
}
