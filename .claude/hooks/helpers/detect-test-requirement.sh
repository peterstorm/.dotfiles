#!/bin/bash
# Detect if a task requires new tests based on description keywords
# Usage: detect-test-requirement.sh "task description"
#    or: echo "task description" | detect-test-requirement.sh
#
# Exit 0 + prints "false" = new_tests_required: false (no new tests needed)
# Exit 1 + prints "true"  = new_tests_required: true (new tests needed)

DESCRIPTION="$1"
[[ -z "$DESCRIPTION" && ! -t 0 ]] && DESCRIPTION=$(cat)
[[ -z "$DESCRIPTION" ]] && { echo "true"; exit 1; }

# Convert to lowercase for matching
DESC_LOWER=$(echo "$DESCRIPTION" | tr '[:upper:]' '[:lower:]')

# Keywords that indicate no new tests required
NO_TEST_PATTERNS=(
  'migrat'           # migration, migrate
  'config'           # config, configuration
  'schema'
  'rename'           # rename, renaming
  'bump'
  'version'
  'refactor'         # refactor, refactoring
  'cleanup'
  'clean-up'
  'typo'
  'docs'
  'documentation'
  'readme'
  'interface update' # interface updates (usually renames)
  '→'                # arrow often indicates rename
  '->'               # ascii arrow
)

for pattern in "${NO_TEST_PATTERNS[@]}"; do
  if [[ "$DESC_LOWER" == *"$pattern"* ]]; then
    echo "false"
    exit 0
  fi
done

echo "true"
exit 1
