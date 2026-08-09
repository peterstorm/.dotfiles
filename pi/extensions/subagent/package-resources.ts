import * as fs from "node:fs";
import * as path from "node:path";

type PackageSetting = string | { source?: unknown };

function packageSource(entry: PackageSetting): string | null {
  if (typeof entry === "string") return entry;
  return typeof entry?.source === "string" ? entry.source : null;
}

function isLocalPackageSource(source: string): boolean {
  return path.isAbsolute(source) || source.startsWith("./") || source.startsWith("../");
}

function isDirectory(candidate: string): boolean {
  try {
    return fs.statSync(candidate).isDirectory();
  } catch {
    return false;
  }
}

/** Resolve local package roots declared in a Pi agent settings file. */
export function resolveLocalPackageRoots(agentDir: string): string[] {
  try {
    const settingsPath = path.join(agentDir, "settings.json");
    if (!fs.existsSync(settingsPath)) return [];

    const settings = JSON.parse(fs.readFileSync(settingsPath, "utf-8")) as { packages?: PackageSetting[] };
    const roots = (settings.packages ?? [])
      .map(packageSource)
      .filter((source): source is string => source !== null && isLocalPackageSource(source))
      .map((source) => path.resolve(agentDir, source))
      .filter((root) => fs.existsSync(path.join(root, "package.json")));

    return [...new Set(roots)];
  } catch {
    return [];
  }
}

/**
 * Agents are not a native Pi package resource. Discover the conventional
 * agents/ directory from each configured local package.
 */
export function resolvePackageAgentDirs(agentDir: string): string[] {
  return resolveLocalPackageRoots(agentDir)
    .map((root) => path.join(root, "agents"))
    .filter(isDirectory);
}

function declaredSkillDirs(root: string): string[] {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf-8")) as {
      pi?: { skills?: unknown };
    };
    const declared = manifest.pi?.skills;
    if (!Array.isArray(declared)) return [];
    return declared
      .filter((entry): entry is string => typeof entry === "string")
      .map((entry) => path.resolve(root, entry));
  } catch {
    return [];
  }
}

/**
 * Skill directories for each configured local package: whatever the manifest
 * declares in pi.skills, falling back to the conventional skills/ directory.
 *
 * Without the fallback the skill map is empty for a package that ships skills/
 * but declares only pi.extensions — as Loom does — so `skills:` frontmatter on
 * any agent Loom has not already rendered resolves to nothing.
 */
export function resolvePackageSkillDirs(agentDir: string): string[] {
  return resolveLocalPackageRoots(agentDir).flatMap((root) => {
    const declared = declaredSkillDirs(root);
    return (declared.length > 0 ? declared : [path.join(root, "skills")]).filter(isDirectory);
  });
}

/**
 * Whether an agent body already carries a preloaded copy of `skill`.
 *
 * Loom renders its own Pi agents with the skill inlined under
 * "## Preloaded Loom Skill: <name>", so injecting the same skill again would
 * put its entire body in the system prompt twice.
 */
export function hasPreloadedSkill(body: string, skill: string): boolean {
  const escaped = skill.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`^##[ \\t]+Preloaded\\b[^\\n]*\\bSkill:[ \\t]*${escaped}[ \\t]*$`, "m").test(body);
}
