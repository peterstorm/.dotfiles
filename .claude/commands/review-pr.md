---
description: "Comprehensive PR review using specialized agents"
argument-hint: "[review-aspects] [--files file1,file2] [--task T1]"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Task"]
---

# Comprehensive PR Review

Run a comprehensive pull request review using multiple specialized agents, each focusing on a different aspect of code quality.

**Arguments:** "$ARGUMENTS"

## Review Workflow

### 1. Determine Review Scope

**Parse arguments for:**
- `--files file1,file2,...` - Explicit file list (comma-separated)
- `--task T1` - Task ID for wave-gate integration (writes breadcrumb)
- Review aspects: code, errors, tests, types, comments, simplify, all

**If --files provided:** Use those files instead of git diff
**If --task provided:** Write breadcrumb to `.claude/state/review-invocations.json`:

```bash
# Write breadcrumb when --task provided
TASK_ID="<extracted from args>"
mkdir -p .claude/state
INVOCATIONS=".claude/state/review-invocations.json"
if [ -f "$INVOCATIONS" ]; then
  jq --arg task "$TASK_ID" --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {($task): $time}' "$INVOCATIONS" > "$INVOCATIONS.tmp" && mv "$INVOCATIONS.tmp" "$INVOCATIONS"
else
  echo "{\"$TASK_ID\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$INVOCATIONS"
fi
```

**Otherwise:** Check git status to identify changed files

### 2. Available Review Aspects

- **code** - General code review for project guidelines and bugs
- **errors** - Check error handling for silent failures (Either patterns)
- **tests** - Review test coverage quality and completeness
- **types** - Analyze type design and invariants
- **comments** - Analyze code comment accuracy
- **simplify** - Simplify code for clarity (run after other reviews pass)
- **all** - Run all applicable reviews (default)

### 3. Identify Changed Files

**If --files provided:**
Use the explicit file list directly.

**Otherwise:**
```bash
git diff --name-only
git diff --cached --name-only
```

Check if PR already exists: `gh pr view`

### 4. Determine Applicable Reviews

Based on changes:
- **Always**: code-reviewer (general quality)
- **If error handling changed**: silent-failure-hunter
- **If test files changed or new logic added**: pr-test-analyzer
- **If types added/modified**: type-design-analyzer
- **If comments/docs added**: comment-analyzer
- **After other reviews pass**: code-simplifier (polish)

### 5. Launch Review Agents

**For comprehensive review, launch these agents in parallel:**

1. **code-reviewer** - CLAUDE.md compliance, bugs, architecture
   - Will recommend delegation to: security-expert, keycloak-skill, architecture-tech-lead, frontend-design-skill

2. **silent-failure-hunter** - Error handling, Either patterns, silent failures

3. **pr-test-analyzer** - Test coverage, property tests, gaps
   - Will recommend delegation to: java-test-engineer, ts-test-engineer

4. **type-design-analyzer** - Invariants, encapsulation, sealed types

5. **comment-analyzer** - Comment accuracy, rot, documentation

**After fixes applied:**
6. **code-simplifier** - Clarity, FP patterns, maintainability

### 6. Aggregate Results

After agents complete, summarize:

```markdown
# PR Review Summary

## Critical Issues (must fix before merge)
- [agent-name]: Issue description [file:line]

## Important Issues (should fix)
- [agent-name]: Issue description [file:line]

## Suggestions (nice to have)
- [agent-name]: Suggestion [file:line]

## Delegation Recommendations
- [ ] security-expert: [reason]
- [ ] keycloak-skill: [reason]
- [ ] java-test-engineer: [reason]
- [ ] ts-test-engineer: [reason]
- [ ] architecture-tech-lead: [reason]

## Strengths
- What's well-done in this PR

## Recommended Action
1. Fix critical issues first
2. Address important issues
3. Consider suggestions
4. Run delegated reviews if recommended
5. Run code-simplifier after fixes
```

## Usage Examples

**Full review (default):**
```
/review-pr
```

**Specific aspects:**
```
/review-pr code errors
/review-pr tests types
/review-pr simplify
```

**With explicit files (for wave-gate):**
```
/review-pr --files components/foo.tsx,lib/bar.ts --task T3
/review-pr code --files src/User.java --task T1
```

**Parallel review:**
```
/review-pr all parallel
```

## Tips

- **Run early**: Before creating PR, not after
- **Focus on changes**: Agents analyze git diff by default (unless --files)
- **Address critical first**: Fix high-priority issues before lower priority
- **Re-run after fixes**: Verify issues are resolved
- **Use delegation**: When agents recommend specialized skills, invoke them
- **Simplify last**: Run code-simplifier after other issues are fixed

## Workflow Integration

**Before committing:**
```
1. Write code
2. Run: /review-pr code errors
3. Fix critical issues
4. Commit
```

**Before creating PR:**
```
1. Stage all changes
2. Run: /review-pr all
3. Address critical and important issues
4. Run delegated reviews (security-expert, java-test-engineer, ts-test-engineer, etc.)
5. Run: /review-pr simplify
6. Create PR with /finalize
```

**Wave-gate integration:**
```
# Called by review-invoker agent with scoped files
/review-pr --files components/report-action-cell.tsx --task T3
```
