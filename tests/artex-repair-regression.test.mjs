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
 * Group `group.artex-audited-identity` (v0.7.0 upgrade, 2026-11-24): the
 * audited tag+sha is written ONLY in the build script; the workflow carries
 * no copy of it, so a version bump cannot leave a stale identity behind.
 *
 * Group `group.artex-secret-key-from-sops` (v0.7.0 upgrade): the at-rest
 * encryption key comes from the sops secret, never from the artex-data PVC
 * that the rollback path deletes.
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
const SCRIPT = path.join(repoRoot, "scripts/artex/build-artex-image.sh");
const DEPLOYMENT = path.join(repoRoot, "k8s/argocd-homelab/artex/deployment.yaml");
const WORKFLOW = path.join(repoRoot, ".github/workflows/build-artex-image.yml");
const SECRETS = path.join(repoRoot, "k8s/argocd-homelab/artex/secrets.enc.yaml");

/** One fixture git repo at tag v0.7.0; returns its absolute path. */
function makeFixture() {
  const dir = mkdtempSync(path.join(tmpdir(), "artex-fixture-"));
  const run = (args) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });
  run(["init", "--quiet"]);
  run(["config", "user.email", "repair-test@example.invalid"]);
  run(["config", "user.name", "repair-test"]);
  writeFileSync(path.join(dir, "README.md"), "# fixture\n");
  run(["add", "README.md"]);
  run(["commit", "--quiet", "-m", "fixture"]);
  run(["tag", "v0.7.0"]);
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
      ARTX_EXPECTED_TAG: "v0.7.0",
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

test("the audited identity lives only in the build script, not in the workflow", () => {
  const script = readFileSync(SCRIPT, "utf8");
  const tag = script.match(/^TAG="\$\{ARTX_EXPECTED_TAG:-(v\d+\.\d+\.\d+)\}"$/m);
  const sha = script.match(/^FULL="\$\{ARTX_EXPECTED_SHA:-([0-9a-f]{40})\}"$/m);
  assert.ok(tag && sha, "the build script must pin a release tag and a full 40-hex sha");
  const workflow = readFileSync(WORKFLOW, "utf8");
  assert.ok(!workflow.includes(tag[1]), `workflow must not repeat the audited tag ${tag[1]}`);
  assert.ok(!workflow.includes(sha[1].slice(0, 8)), `workflow must not repeat the audited sha ${sha[1].slice(0, 8)}`);
  assert.match(workflow, /bash scripts\/artex\/build-artex-image\.sh/);
});

test("ARTEX_SECRET_KEY comes from the sops secret, not the artex-data volume", () => {
  const text = readFileSync(DEPLOYMENT, "utf8");
  assert.match(
    text,
    /- name: ARTEX_SECRET_KEY\n\s+valueFrom:\n\s+secretKeyRef:\n\s+name: artex-secrets\n\s+key: secret-key\n/,
    "ARTEX_SECRET_KEY must be wired from artex-secrets/secret-key",
  );
  // The encrypted file names its keys in clear: the key must exist there.
  assert.match(readFileSync(SECRETS, "utf8"), /^\s+secret-key: ENC\[/m);
});
