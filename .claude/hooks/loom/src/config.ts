/**
 * Shared constants for loom hooks.
 * Skills reference these values — update docs if changed.
 */

import type { Phase } from "./types";

/** Markers above this trigger mandatory clarify phase */
export const CLARIFY_THRESHOLD = 3;

/** Valid phase ordering */
export const PHASE_ORDER: readonly Phase[] = [
  "init", "brainstorm", "specify", "clarify", "architecture", "decompose", "execute",
] as const;

/** Phase agents → map to their phase */
export const PHASE_AGENT_MAP: Record<string, Phase> = {
  "brainstorm-agent": "brainstorm",
  "specify-agent": "specify",
  "clarify-agent": "clarify",
  "architecture-agent": "architecture",
  "decompose-agent": "decompose",
};

/** Impl agents → all map to "execute" phase */
export const IMPL_AGENTS = new Set([
  "code-implementer-agent",
  "java-test-agent",
  "ts-test-agent",
  "frontend-agent",
  "security-agent",
  "k8s-agent",
  "keycloak-agent",
  "dotfiles-agent",
  "general-purpose",
]);

/** Known agents for task graph validation */
export const KNOWN_AGENTS = new Set([...IMPL_AGENTS]);

/** Utility agents allowed through phase validation */
export const UTILITY_AGENTS = new Set(["Explore", "Plan", "haiku"]);

/** Review/spec-check agents (not impl agents) */
export const REVIEW_AGENTS = new Set(["review-invoker", "spec-check-invoker"]);

/** All agents that map to execute phase (impl + review) */
export const EXECUTE_AGENTS = new Set([...IMPL_AGENTS, ...REVIEW_AGENTS]);

/** Tools that modify files */
export const FILE_MODIFYING_TOOLS = new Set(["Write", "Edit", "MultiEdit"]);

/** Whitelisted helper scripts in guard-state-file */
export const WHITELISTED_HELPERS = [
  "complete-wave-gate",
  "mark-tests-passed",
  "store-review-findings",
  "populate-task-graph",
];

/** State file patterns to guard */
export const STATE_FILE_PATTERNS = /active_task_graph|review-invocations/;

/** Write patterns to block on state files */
export const WRITE_PATTERNS = />>?|mv |cp |tee |sed -i|perl -i|dd |sponge |chmod |python3? .*(open|write)|node .*(writeFile|fs\.)/;

/** Test command patterns (for bash test output parsing) */
export const TEST_COMMAND_PATTERNS = [
  "mvn test", "mvn verify", "mvn -pl",
  "mvnw test", "mvnw verify",
  "./gradlew test", "./gradlew check",
  "gradle test", "gradle check",
  "npm test", "npm run test",
  "npx vitest", "npx jest",
  "yarn test", "pnpm test", "bun test",
  "pytest", "python -m pytest", "python3 -m pytest",
  "cargo test", "go test", "dotnet test",
  "mix test", "make test", "make check",
];

/** Valid phase transitions: from → allowed targets */
export const VALID_TRANSITIONS: Record<string, Phase[]> = {
  "init":         ["brainstorm", "specify"],
  "brainstorm":   ["brainstorm", "specify"],
  "specify":      ["specify", "clarify", "architecture"],
  "clarify":      ["clarify", "architecture"],
  "architecture": ["architecture", "decompose"],
  "decompose":    ["decompose", "execute"],
  "execute":      ["execute"],
};

/** Default task graph path (relative) */
export const TASK_GRAPH_PATH = ".claude/state/active_task_graph.json";

/** Subagent tracking directory */
export const SUBAGENT_DIR = "/tmp/claude-subagents";
