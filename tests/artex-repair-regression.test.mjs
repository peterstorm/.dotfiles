/**
 * Repair-regression check for the ARTEX audit-bond delivery
 * (review run artex-commits-review-1).
 *
 * Group `group.artex-clean-worktree-guard` (finding silent-failure-hunter-1):
 * the build script's clean-worktree assert must treat a FAILED git status
 * probe as a loud refusal, never as "clean" (the old `-z ""` inversion).
 * Historical RED: case 3 exits 0 silently against the pre-fix script.
 *
 * Group `group.artex-image-digest-pin` (finding architecture-tech-lead-1):
 * the deployment's artex image reference must pin the digest, so a GHCR
 * re-push of the mutable tag cannot silently replace the audited build.
 * Historical RED: case 4 fails against the pre-fix tag reference.
 *
 * Runs under the enrolled manifest check:
 *   node --test --test-reporter=junit \
 *     --test-reporter-destination=.loom/completion-reports/artex-repair-regression.xml \
 *     tests/artex-repair-regression.test.mjs
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPT = path.join(repoRoot, "scripts/artex/build-artex-image-v0-6-0.sh");
const DEPLOYMENT = path.join(repoRoot, "k8s/argocd-homelab/artex/deployment.yaml");

/** One fixture git repo at tag v0.6.0; returns its absolute path. */
function makeFixture() {
  const dir = mkdtempSync(path.join(tmpdir(), "artex-fixture-"));
  const run = (args) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });
  run(["init", "--quiet"]);
  run(["config", "user.email", "repair-test@example.invalid"]);
  run(["config", "user.name", "repair-test"]);
  writeFileSync(path.join(dir, "README.md"), "# fixture\n");
  run(["add", "README.md"]);
  run(["commit", "--quiet", "-m", "fixture"]);
  run(["tag", "v0.6.0"]);
  return dir;
}

/** Run the script's provenance assert block only (no docker), in a fixture. */
function runAssert(src) {
  const head = execFileSync("git", ["rev-parse", "HEAD"], { cwd: src, encoding: "utf8" }).trim();
  return spawnSync("bash", [SCRIPT], {
    encoding: "utf8",
    env: {
      ...process.env,
      ARTX_SRC: src,
      ARTX_ASSERT_ONLY: "1",
      ARTX_EXPECTED_TAG: "v0.6.0",
      ARTX_EXPECTED_SHA: head,
    },
  });
}

test("provenance assert block passes a clean audited-tag worktree", () => {
  const dir = makeFixture();
  try {
    const r = runAssert(dir);
    assert.equal(r.status, 0, `stderr: ${r.stderr}`);
    assert.match(r.stdout, /provenance: .* = the audited checkout/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("provenance assert block refuses a dirty worktree by name", () => {
  const dir = makeFixture();
  try {
    writeFileSync(path.join(dir, "README.md"), "# fixture, edited\n");
    const r = runAssert(dir);
    assert.equal(r.status, 1);
    assert.match(r.stderr, /FAIL: .* has uncommitted changes/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("provenance assert block refuses when the git status probe fails (corrupt index)", () => {
  const dir = makeFixture();
  try {
    // Precondition of the fixture: tag+sha probes succeed while status cannot run.
    execFileSync("git", ["rev-parse", "HEAD"], { cwd: dir, encoding: "utf8" });
    writeFileSync(path.join(dir, ".git", "index"), "not-a-real-index-file\n");
    const status = spawnSync("git", ["status", "--porcelain"], { cwd: dir, encoding: "utf8" });
    assert.notEqual(status.status, 0, "fixture precondition: git status must fail on a corrupt index");
    const r = runAssert(dir);
    assert.equal(r.status, 1, `a failed cleanliness probe must refuse the build (stderr: ${r.stderr})`);
    assert.match(r.stderr, /FAIL: cannot verify .* is clean: git status failed/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("deployment pins the artex image by digest, not by mutable tag", () => {
  const text = readFileSync(DEPLOYMENT, "utf8");
  const refs = [...text.matchAll(/image:\s*(ghcr\.io\/peterstorm\/artex\S*)/g)].map((m) => m[1]);
  assert.ok(refs.length > 0, "the deployment must reference the artex image at least once");
  for (const ref of refs) {
    assert.match(
      ref,
      /^ghcr\.io\/peterstorm\/artex@sha256:[0-9a-f]{64}$/,
      `artex image reference must be a digest pin: ${ref}`,
    );
  }
});
