import { afterEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { resolveLocalPackageRoots, resolvePackageAgentDirs } from "./package-resources";

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
