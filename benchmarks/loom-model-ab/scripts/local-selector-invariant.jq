# Local arms are measurable only if every child runs on the arm's exact selector.
# Input: pi/model-routing.json. True when at least one rule can apply to a local
# parent (parentClass "local" or unconstrained) and every such rule gives
# children either the parent itself, or the model its provider serves now at the
# parent's thinking level (a served target with no pinned thinkingLevel).
#
# Shared by scripts/verify-harness.sh (gates every attended run) and
# tests/loom-model-ab-contract.sh (which also feeds it mutated policies).
. as $policy
| def keeps_selector:
    .use == {"kind": "parent"} or
    (.use.kind == "named" and
      ($policy.targets[.use.target]
        | type == "object" and (.served | type == "string") and .thinkingLevel == null));
  [$policy.rules[] | select(.when.parentClass == "local" or .when.parentClass == null)] as $local
| ($local | length > 0) and all($local[]; keeps_selector)
