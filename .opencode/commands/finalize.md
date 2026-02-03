---
description: Finalize work - branch, commit, PR, verify issue checkboxes
allowed-tools: Bash(git *), Bash(gh *)
---

Finalize the current work by handling branching, committing, PR creation, and issue verification.

Execute these steps in order, being context-aware at each step:

## Step 1: Branch Check

Run `git branch --show-current` and `git status`.

- If on `main` or `master`:
  - Ask user what branch name to use (suggest based on recent work context)
  - Create and checkout the branch: `git checkout -b <branch-name>`
- If already on a feature branch: continue to next step

## Step 2: Uncommitted Changes Check

Run `git status` to check for uncommitted changes.

- If there are staged or unstaged changes:
  - Run `git diff --stat` and `git diff --cached --stat` to summarize
  - Draft a commit message based on the changes
  - Show the proposed commit message to user and ask for confirmation
  - If confirmed, stage all changes and commit (follow the git commit rules from project guidelines)
- If no changes: continue to next step

## Step 3: Push and PR Check

Run `git log origin/main..HEAD --oneline` (or origin/master) to see unpushed commits.
Run `gh pr list --head $(git branch --show-current)` to check for existing PR.

- If there are unpushed commits and no PR exists:
  - Push the branch: `git push -u origin $(git branch --show-current)`
  - Create PR using `gh pr create` following the PR creation rules from project guidelines
  - Show the PR URL to user
- If PR already exists:
  - If there are new commits, push them
  - **Reconcile PR description with actual commits:**
    1. Parse ALL commit messages on branch: `git log origin/main..HEAD --format="%s"`
    2. Get current PR description: `gh pr view --json body -q '.body'`
    3. **Cross-check**: Identify features/phases in commits that are missing from PR description
    4. **Rebuild PR description** to include all work done (don't just append - ensure completeness)
    5. Update PR: `gh pr edit --body <complete-description>`
  - Show the existing PR URL
- If no commits to push and PR exists: continue to next step

**Critical**: PR description MUST accurately reflect ALL commits on the branch, not just recent changes. Parse commit messages for phases, features, fixes, and ensure each is documented.

## Step 4: Issue Checkbox Verification

Look for a related GitHub issue. Search strategies:
1. Check PR description for issue references (#number or "closes #number")
2. Run `gh issue list --state open --limit 10` and look for related issues
3. Ask user which issue to check if unclear

Once issue is identified:
- Run `gh issue view <number>` to get the issue body
- Parse all checkbox items: `- [ ]` (unchecked) and `- [x]` (checked)
- **Cross-check issue with commits**: Compare issue checkboxes against commit messages to verify all completed work is checked
- Report:
  - Total checkboxes
  - Checked count
  - Unchecked count with their text
  - Overall completion percentage
  - **Discrepancies**: Checkboxes that should be checked based on commits but aren't

If all checkboxes are checked:
- Congratulate and suggest closing the issue or marking PR ready for review

If some checkboxes remain:
- List the unchecked items
- Identify which ones are actually done (based on commits) but not checked
- Ask if user wants to continue working or if some items should be marked complete

## Output Format

Provide a clear summary at each step:

```
Step 1: Branch
  Current: feature/abac-validation-property-tests
  Status: Already on feature branch

Step 2: Changes
  Staged: 3 files
  Unstaged: 1 file
  Action: Committed with message "..."

Step 3: PR
  Status: PR #67 exists
  URL: https://github.com/...
  Commits: 8 commits on branch
  Reconciliation: Found Phase 4 in commits but missing from PR description
  Action: Pushed 2 new commits, rebuilt PR description to include all 5 phases

Step 4: Issue #66
  Total: 12 checkboxes
  Checked: 10 (83%)
  Remaining:
    - [ ] Phase 4: Split steps (DONE in commits - should be checked!)
    - [ ] Golden test unchanged (verified)
  Discrepancies: 1 checkbox should be checked based on commits
```

## Notes

- Be conversational and ask for confirmation before destructive/public actions (commits, pushes, PR creation)
- If any step fails, stop and report the error clearly
- Use the user's git and PR conventions from project guidelines
- **Reconciliation is critical**: Always verify PR description matches ALL commits, and issue checkboxes match completed work
- Don't just append to PR descriptions - rebuild them to ensure completeness and accuracy
