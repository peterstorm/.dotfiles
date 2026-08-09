import { afterEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  hasPreloadedSkill,
  resolveLocalPackageRoots,
  resolvePackageAgentDirs,
  resolvePackageSkillDirs,
} from "./package-resources";

const scratch: string[] = [];

afterEach(() => {
  for (const dir of scratch.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function fixture(): { agentDir: string; first: string; second: string } {
  const root = mkdtempSync(join(tmpdir(), "pi-package-agents-"));
  scratch.push(root);
  const agentDir = join(root, "agent");
  const first = join(root, "first-package");
  const second = join(root, "second-package");
  mkdirSync(agentDir, { recursive: true });
  for (const pkg of [first, second]) {
    mkdirSync(join(pkg, "agents"), { recursive: true });
    writeFileSync(join(pkg, "package.json"), JSON.stringify({ name: pkg }));
  }
  return { agentDir, first, second };
}

describe("local Pi package agent discovery", () => {
  it("discovers conventional agents directories from string and object package entries", () => {
    const { agentDir, first, second } = fixture();
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({
      packages: [
        "../first-package",
        { source: "../second-package" },
        "npm:@example/remote-package",
      ],
    }));

    expect(resolveLocalPackageRoots(agentDir)).toEqual([first, second]);
    expect(resolvePackageAgentDirs(agentDir)).toEqual([
      join(first, "agents"),
      join(second, "agents"),
    ]);
  });

  it("deduplicates roots and ignores packages without a package manifest or agents directory", () => {
    const { agentDir, first, second } = fixture();
    rmSync(join(second, "agents"), { recursive: true });
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({
      packages: ["../first-package", { source: "../first-package" }, "../second-package", "../missing"],
    }));

    expect(resolveLocalPackageRoots(agentDir)).toEqual([first, second]);
    expect(resolvePackageAgentDirs(agentDir)).toEqual([join(first, "agents")]);
  });

  it("fails closed to an empty package set for malformed settings", () => {
    const { agentDir } = fixture();
    writeFileSync(join(agentDir, "settings.json"), "not-json");

    expect(resolveLocalPackageRoots(agentDir)).toEqual([]);
    expect(resolvePackageAgentDirs(agentDir)).toEqual([]);
  });
});

describe("local Pi package skill discovery", () => {
  it("prefers the declared pi.skills entries over the convention", () => {
    const { agentDir, first } = fixture();
    mkdirSync(join(first, "declared-skills"), { recursive: true });
    mkdirSync(join(first, "skills"), { recursive: true });
    writeFileSync(
      join(first, "package.json"),
      JSON.stringify({ name: "first", pi: { skills: ["./declared-skills"] } }),
    );
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ packages: ["../first-package"] }));

    expect(resolvePackageSkillDirs(agentDir)).toEqual([join(first, "declared-skills")]);
  });

  // Loom ships skills/ but declares only pi.extensions; without this fallback
  // every `skills:` frontmatter entry resolves to nothing.
  it("falls back to the conventional skills directory when the manifest declares none", () => {
    const { agentDir, first, second } = fixture();
    mkdirSync(join(first, "skills"), { recursive: true });
    writeFileSync(join(first, "package.json"), JSON.stringify({ name: "first", pi: { extensions: ["./pi/extension.ts"] } }));
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({
      packages: ["../first-package", "../second-package"],
    }));

    // second-package has no skills/ at all, so it contributes nothing.
    expect(resolvePackageSkillDirs(agentDir)).toEqual([join(first, "skills")]);
    expect(resolvePackageSkillDirs(agentDir)).not.toContain(join(second, "skills"));
  });

  // Loom renders its agents with the skill body already inlined; injecting the
  // same skill again puts the whole thing in the system prompt twice.
  it("detects a skill Loom has already inlined", () => {
    const body = "# Designer\n\n## Preloaded Loom Skill: architecture-tech-lead\n\nbody...";

    expect(hasPreloadedSkill(body, "architecture-tech-lead")).toBe(true);
    expect(hasPreloadedSkill(body, "grill")).toBe(false);
  });

  it("detects the extension's own injected heading", () => {
    expect(hasPreloadedSkill("## Preloaded Skill: grill\n", "grill")).toBe(true);
  });

  it("does not mistake a mention of the skill for a preload", () => {
    const body = "Use the `architecture-tech-lead` skill.\n### Preloaded Loom Skill: architecture-tech-lead\n";

    // A prose mention, and a heading at the wrong level, are not preloads.
    expect(hasPreloadedSkill(body, "architecture-tech-lead")).toBe(false);
    expect(hasPreloadedSkill("## Preloaded Skill: architecture", "architecture-tech-lead")).toBe(false);
  });

  it("ignores declared entries that are not directories and non-string entries", () => {
    const { agentDir, first } = fixture();
    writeFileSync(
      join(first, "package.json"),
      JSON.stringify({ name: "first", pi: { skills: ["./nowhere", 42] } }),
    );
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ packages: ["../first-package"] }));

    expect(resolvePackageSkillDirs(agentDir)).toEqual([]);
  });
});
