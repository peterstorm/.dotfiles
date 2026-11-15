# ARTEX commits remediation plan (2026-11-15)

## Branch and venue

- Branch `main` in the review clone `/tmp/dotfiles-artex-review`, HEAD `c2e1cc94`
  (the newest artex commit), review baseline `335be989` (parent of the range).
  The registered review needed a venue where origin/main sits below the range;
  the live `~/.dotfiles` checkout is 28 commits ahead with unrelated WIP and is
  not touched by this run. After the remediation commit, origin/main is
  fast-forwarded and `~/.dotfiles` merges it.

## Exact scope (frozen by the review)

13 files, additions ~529:
`.github/workflows/build-artex-image.yml`, `docs/plans/2026-11-15-artex-k3s.md`,
`k8s/argocd-homelab/artex/{deployment,ghcr-pull-secret.enc,ingress,kustomization,pvc,secret-generator,secrets.enc,service}.yaml`,
`k8s/argocd-homelab/cloudflared/configmap.yaml`,
`k8s/terraform-homelab/cloudflare/main.tf`,
`scripts/artex/build-artex-image-v0-6-0.sh`.
The interleaved commit `fef6be24` (probe-glm-drift, python) is not artex and is
out of scope.

## Review Run Directory

- Review: `.claude/reviews/review-and-fix-runs/artex-commits-review-1`
  (result digest `f8e6bb6a0145c3d073324b463a9a87f17e89b8ba4983803fd7b96190fe87da3f`)
- Policy: `.claude/reviews/review-and-fix-runs/artex-advisory-policy-1`
  (disposition digest `ea193e49b1047249cc10a89e518862005a28d228d00cb15c8deabff6b229ba66`)

## Surviving criticals — dispositions

Engine counts: 2 surviving critical, 0 refuted, 13 advisory.

### 1. `silent-failure-hunter-1` — repaired (group `group.artex-clean-worktree-guard`)

Claim: `scripts/artex/build-artex-image-v0-6-0.sh:37` — the clean-worktree audit-bond
check counts its own failure as a pass: when `git status --porcelain 2>/dev/null`
fails, the substitution is empty, `[ -z "" ]` succeeds, and the script builds and
publishes while printing "the audited checkout". Panel 3/3 upheld.

### 2. `architecture-tech-lead-1` — repaired (group `group.artex-image-digest-pin`)

Claim: `k8s/argocd-homelab/artex/deployment.yaml:40` — the deployment consumes the
image by the mutable registry tag `sha-a13c68cb`; a re-push silently replaces the
audited image under an unchanged, still-attesting deployment. Panel 2/3 upheld
(reproduction + blast-radius uphold; intent lens refuted on house-convention grounds —
the convention argument addresses the tag-vs-digest style choice, not the
silent-substitution mechanics the majority upheld).

## Declared Repair Groups

### `group.artex-clean-worktree-guard` (finding: silent-failure-hunter-1)

- Root cause (DECLARED): the guard tests `-z "$(git status --porcelain 2>/dev/null)"`,
  so a failed probe yields an empty substitution that the `-z` test reads as "clean" —
  probe failure is inverted into a pass and the build proceeds on unverified cleanliness.
- Invariant (DECLARED): the build refuses with a named FAIL and exit 1 whenever the
  worktree-cleanliness probe fails, and proceeds only on an observed-clean status
  output; "cannot verify" is never "clean".
- Siblings (DECLARED): none-declared — the only other swallowed-failure sites in the
  frozen scope are the workflow's `|| true` steps (lines 49, 93), which are distinct
  defects dispositioned as accepted advisories (silent-failure-hunter-4/5), not
  siblings of this guard inversion.
- Selected check: `project:artex-repair-regression`
- Historical RED (DECLARED): the corrupt-index fixture case (git status fails) exits 0
  with no FAIL diagnostic against the pre-fix script — the exact silent-pass the
  finding claims — and only passes after the fix.

### `group.artex-image-digest-pin` (finding: architecture-tech-lead-1)

- Root cause (DECLARED): the consumption seam references the audited image by mutable
  registry tag, so the provenance the manifest attests is enforced only at build time;
  a tag overwrite cannot be distinguished from the pinned build by any GitOps signal.
- Invariant (DECLARED): the deployment's artex image reference identifies the exact
  audited artifact by digest (`ghcr.io/peterstorm/artex@sha256:…`), so a registry
  re-push cannot change what runs without a GitOps-visible manifest change.
- Siblings (DECLARED): none-declared — the only artex image references in the frozen
  scope are the artex container's single `image:` line in deployment.yaml; the
  postgres sidecar image is not part of the audit bond, and no other file in scope
  references the artex image.
- Selected check: `project:artex-repair-regression`
- Historical RED (DECLARED): the deployment-pin test case fails against the pre-fix
  manifest (tag reference `:sha-a13c68cb`, no `@sha256:`) and passes after the pin.
- Fix value: `sha256:519e58f274b3a96cb16e83a43d30741c67e31443305ba17572ac11d8df9313b4`
  — observed as the running container's imageID on pod `artex-7cb45864fb-b8v68`
  (what actually runs today), the digest GHCR served for the audited build of run
  43685680995. A comment keeps the tag identity (`sha-a13c68cb`, v0.6.0 audited).

Both groups select the same check ID; the engine runs it once.

## Selected check — `project:artex-repair-regression`

- Enrolled in `.loom/verification-manifest.json`:
  `node --test --test-reporter=junit --test-reporter-destination=.loom/completion-reports/artex-repair-regression.xml tests/artex-repair-regression.test.mjs` (cwd `.`),
  report `{"kind":"required-file","path":".loom/completion-reports/artex-repair-regression.xml"}`.
- The report path is beneath `.loom/completion-reports/`, untracked and Git-ignored
  via the added `.loom/` ignore.
- `tests/artex-repair-regression.test.mjs` is a NEW file outside the frozen review
  scope → supportPath.

## Advisory dispositions (published: artex-advisory-policy-1)

| # | Finding | Decision | Fix applied |
|---|---------|----------|-------------|
| 0 | code-reviewer-1 (script:52) | accepted | stamp capture gains `\|\| true` so the FAIL diagnostic is reachable |
| 1 | code-reviewer-2 (script:53) | accepted | expected stamp derived from TAG (`${TAG#v}`), grep pattern escaped from it |
| 2 | silent-failure-hunter-2 (script:52) | accepted | same fix as code-reviewer-1 |
| 3 | silent-failure-hunter-3 (script:57) | accepted | per-tool loop gate naming missing tools |
| 4 | silent-failure-hunter-4 (workflow:49) | accepted | assert `docker info` DockerRootDir == /mnt/docker |
| 5 | silent-failure-hunter-5 (workflow:93) | accepted | `digest: unavailable` fallback |
| 6 | comment-analyzer-1 (workflow:6) | accepted | header states full delta incl. Docker Hub login secrets |
| 7 | comment-analyzer-2 (plan:34) | accepted | Layout: 8 files, ghcr-pull-secret.enc.yaml listed |
| 8 | comment-analyzer-3 (plan:56) | accepted | artex-data 2Gi documented (data + keys subPath) |
| 9 | comment-analyzer-4 (plan:49) | accepted | JWT_KEY_DIR + TRUSTED_PROXIES added to env list |
| 10 | architecture-tech-lead-2 (workflow:37) | deferred | script-side derivation lands with #1; workflow consumption deferred (parse coupling, on-demand build) |
| 11 | architecture-tech-lead-3 (ghcr-pull-secret.enc.yaml:1) | accepted | rotation-pointer comment beside the copy |
| 12 | architecture-tech-lead-4 (deployment.yaml:77) | accepted | JWT key lifecycle decision comment |

Refuted findings: none — no refutation audit owed.

## Support paths (outside the frozen review scope)

- `docs/plans/2026-11-15-artex-commits-remediation.md` (this plan; the repo's
  `.claude/plans/` is git-ignored, so the plan lives in the tracked plans dir)
- `tests/artex-repair-regression.test.mjs` (new regression check)
- `.gitignore` (makes `.loom/verification-manifest.json` tracked and keeps
  `.loom/completion-reports/` ignored, as the required report needs)
- `.loom/verification-manifest.json` (the enrolled check configuration, installed
  through the sanctioned helper; Git-visible untracked at start)

## Validation commands (Phase 3, mine — not remediation evidence)

- `bash -n scripts/artex/build-artex-image-v0-6-0.sh`
- `node --test tests/artex-repair-regression.test.mjs` (scratch run, not at the
  enrolled report path)
- `kubectl apply --dry-run=client -f k8s/argocd-homelab/artex/deployment.yaml`
- YAML sanity of the edited workflow via its own parser at push time (Actions), plus
  structural check of the manifest: `bun -e` parse of `.loom/verification-manifest.json`.

## Historical RED note

Both groups declare Historical RED against the same check; the corrupt-index case and
the deployment-pin case each fail against the pre-fix bytes and pass post-fix. The
engine observes the check fresh on the repaired candidate; RED is DECLARED, not
replayed.
