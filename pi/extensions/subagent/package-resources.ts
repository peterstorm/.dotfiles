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
