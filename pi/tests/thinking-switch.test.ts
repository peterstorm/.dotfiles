// Contract for overlays/patches/pi-model-default-thinking.patch: the pure rule that picks the
// thinking level when switching models. Imported from the package's dist because the rule is an
// internal export (not in the package `exports` map); pi/verify.sh links node_modules for it.
import { describe, expect, it } from "bun:test";
import { resolveThinkingLevelForSwitch } from "../../node_modules/@earendil-works/pi-coding-agent/dist/core/agent-session.js";

type Level = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
type Inputs = Readonly<{
  scoped?: Level;
  perModel?: Level;
  pinned?: Level;
  modelDefault?: Level;
  settingsDefault?: Level;
  current?: Level;
  currentIsModelDefault?: boolean;
}>;

const resolve = resolveThinkingLevelForSwitch as (inputs: Inputs) => { level: Level; source: string };

describe("thinking level on model switch", () => {
  it("applies precedence scoped > per-model > pinned > model default > baseline for every input combination", () => {
    // Distinct level per slot, so the result identifies which input won.
    const slots = [
      ["scoped", "off", "scoped"],
      ["perModel", "minimal", "per-model"],
      ["pinned", "low", "pinned"],
      ["modelDefault", "medium", "model-default"],
      ["settingsDefault", "high", "baseline"],
    ] as const;
    for (let mask = 0; mask < 1 << slots.length; mask++) {
      const inputs: Record<string, Level> = {};
      slots.forEach(([key, level], bit) => {
        if (mask & (1 << bit)) inputs[key] = level;
      });
      const winner = slots.find(([key]) => key in inputs);
      const result = resolve({ ...inputs, current: "xhigh" });
      if (winner) {
        expect(result).toEqual({ level: winner[1], source: winner[2] });
      } else {
        // Nothing configured: keep the current level, as upstream does.
        expect(result).toEqual({ level: "xhigh", source: "baseline" });
      }
    }
  });

  it("falls back to the global default, never to a level that only came from a model default", () => {
    expect(resolve({ settingsDefault: "low", current: "max", currentIsModelDefault: true })).toEqual({
      level: "low",
      source: "baseline",
    });
    // No global default: a level inherited from a model default must not leak to the next model.
    const leaked = resolve({ current: "max", currentIsModelDefault: true });
    expect(leaked.source).toBe("baseline");
    expect(leaked.level).not.toBe("max");
    // A level the session chose (not a model default) is kept.
    expect(resolve({ current: "high", currentIsModelDefault: false })).toEqual({
      level: "high",
      source: "baseline",
    });
  });

  it("lets a model default beat the global default but not a pin", () => {
    expect(resolve({ modelDefault: "max", settingsDefault: "low" }).level).toBe("max");
    expect(resolve({ pinned: "low", modelDefault: "max", settingsDefault: "high" }).level).toBe("low");
  });
});
