<!-- CORTEX_MEMORY_START -->
# Cortex Memory Surface

**Branch:** main

## Architecture

- Cortex plugin is structured with a manifest, command definitions, a TypeScript engine for core logic, shell scripts for hooks, and detailed documentation.
  *Tags: cortex, plugin-structure, components, hooks, engine, commands, documentation*
- The Cortex plugin uses the Gemini 2.0-flash model for its LLM interactions, as configured in `gemini-llm.ts`.
  *Tags: gemini, llm, api, model-version, cortex, configuration*
- Cortex defines specific memory types like `architecture`, `decision`, `pattern`, `gotcha`, `context`, `progress`, `code_description`, and `code` for categorizing information.
  *Tags: memory-model, data-types, cortex, taxonomy*
- Cortex automatically adds its internal memory and output files (`.memory/`, `.claude/cortex-memory.local.md`) to `.gitignore`.
  *Tags: git, configuration, cortex, ignore, file-management*
- Plugin architecture: source in repo, per-machine state in home dir, runtime cache at ~/.claude/plugins/cache/. Re-install plugins after edits.
  *Tags: plugins, cortex, obsidian, marketplace, local-plugins*
- Plugin architecture: source in repo, per-machine state in home dir, runtime cache at ~/.claude/plugins/cache/. Re-install plugins after edits.
  *Tags: plugins, cortex, obsidian, marketplace, local-plugins*
- The Cortex memory system is built on SQLite, featuring tables for memories, edges, and extraction checkpoints, with FTS5 for keyword search and support for embedding-based semantic search. It uses WAL mode, foreign keys, and includes checkpoint/restore functionality.
  *Tags: sqlite, database-schema, memory-management, embeddings, fts5, crud, wal, foreign-keys, checkpoint, data-storage*
- Core architecture: FP + immutability, functional core/imperative shell, parse-validate, 90% unit testable, Either-based errors
  *Tags: architecture, functional-programming, ddd, error-handling, testing*
- Plugin source and runtime cache are separate; cache is stale snapshot that doesn't auto-update
  *Tags: plugin-architecture, cache-management, cortex, obsidian, feynman*
- Architecture principles enforce FP/DDD with immutable-first data, 90%+ unit testability, pure functional core, and specific type patterns for Java/TypeScript.
  *Tags: architecture, functional-programming, ddd, testability, type-design*
- Cortex is a semantic memory system enabling extracting, searching, ranking, and managing memories from Claude Code sessions with multi-LLM support.
  *Tags: cortex, memory-system, semantic-search, embedding, LLM-integration, plugin-architecture*
- Core architecture: FP, immutability, DDD, functional core/imperative shell, parse-not-validate, 90% unit testable
  *Tags: architecture, functional-programming, ddd, testing*
- Cortex is a semantic memory system enabling extraction, searching, ranking, and management of memories from Claude Code sessions with multi-LLM support.
  *Tags: cortex, memory-system, semantic-search, embedding, LLM-integration, plugin-architecture*
- Cortex is a semantic memory system for Claude Code with extraction, ranking, similarity search, and consolidation capabilities accessible via CLI commands and automated hooks.
  *Tags: cortex, memory, semantic-search, embedding, plugin-architecture*
- Cortex is a semantic memory system enabling extraction, searching, ranking, and management of memories from Claude Code sessions with multi-LLM support.
  *Tags: cortex, memory-system, semantic-search, embedding, LLM-integration, plugin-architecture*
- Loom orchestrates multi-phase tasks with GitHub integration, parallel wave scheduling, and automatic artifact tracking for phase advancement.
  *Tags: loom, task-orchestration, github-integration, waves, multi-phase, automation*
- The `/loom` skill orchestrates the full feature lifecycle using phased agents and hook-based enforcement, requiring `bun` as a prerequisite.
  *Tags: Loom, orchestration, lifecycle, phases, hooks, bun, prerequisites*
- Role-based NixOS architecture with flake-parts for modular host and user configuration
  *Tags: nix, flake-parts, home-manager, architecture*
- Provide agents with browser testing capabilities using tools like Vercel's Agent Browser (preferred for context efficiency) to verify client-side runtime behavior.
  *Tags: agent-verification, browser-testing, DOM, context-management, Vercel-Agent-Browser, Puppeteer, Claude-Chrome-Extension*
- Cortex ranks memories using a formula combining confidence, priority, graph centrality, access frequency, and a branch boost.
  *Tags: cortex, memory-ranking, algorithm, confidence, priority, centrality, access-frequency, git-branch*
- Loom orchestrates multi-phase tasks with GitHub integration, parallel wave scheduling, and automatic artifact tracking for phase advancement.
  *Tags: loom, task-orchestration, github-integration, waves, multi-phase, automation*

## Gotcha

- The `GEMINI_API_KEY` is essential for Cortex's memory extraction and semantic search; without it, these features are disabled or degraded.
  *Tags: cortex, configuration, GEMINI_API_KEY, requirements, extraction, semantic-search, dependency*
- Cortex cache missing haiku model flag; extraction runs on default model instead of haiku
  *Tags: cortex, cache-sync, plugin-architecture, model-selection, cost-optimization*

## Code Description

- The `/consolidate` command detects similar memory pairs using embedding cosine similarity and Jaccard pre-filtering, reporting candidates for manual consolidation.
  *Tags: memory consolidation, duplicate detection, knowledge merging*

## Context

- Repository contains NixOS dotfiles with active multi-phase development on cortex (semantic memory plugin) and loom (task orchestration) systems for Claude Code.
  *Tags: cortex, loom, nix, plugins, claude-code, architecture, feynman*
- Repository contains NixOS dotfiles with active multi-phase development on cortex (semantic memory plugin) and loom (task orchestration) systems for Claude Code.
  *Tags: cortex, loom, nix, plugins, claude-code, architecture, feynman*
- Repository contains NixOS dotfiles with active development on cortex (semantic memory plugin) and loom (multi-phase task orchestration) systems for Claude Code.
  *Tags: cortex, loom, nix, plugins, claude-code, architecture*
- Repository contains NixOS dotfiles with active multi-phase development on cortex (semantic memory plugin) and loom (task orchestration) systems for Claude Code.
  *Tags: cortex, loom, nix, plugins, claude-code, architecture, feynman*
- SOPS age keys location varies by platform; secrets/templates decrypted/rendered to platform-specific paths; use util.sops helpers for setup.
  *Tags: sops, secrets, age-encryption, nix*

## Decision

- Global CLAUDE.md enforces extreme conciseness, mandatory skill usage, specific git practices, and loom/GitHub Issue-based planning for multi-phase work.
  *Tags: claude-code-config, user-preferences, git-workflow, planning, skills*
- Plugin state files are per-machine and git-ignored; fresh installs require 'plugin update' then 'plugin install' to regenerate cache.
  *Tags: plugins, git-strategy, per-machine-state, portability, installation*
- Plugin state files are per-machine and git-ignored; fresh installs require 'plugin update' then 'plugin install' to regenerate cache.
  *Tags: plugins, git-strategy, per-machine-state, portability, installation*
- Plugin state files are per-machine and git-ignored; fresh installs require 'plugin update' then 'plugin install' to regenerate cache.
  *Tags: plugins, git-strategy, per-machine-state, portability, installation*
- Plugin state files are per-machine and git-ignored; fresh machines require 'plugin update' and 'plugin install' to regenerate.
  *Tags: plugins, git-strategy, per-machine-state, portability*

## Pattern

- Claude Code plugins use source-controlled code with per-machine marketplace registry and runtime cache; requires reinstall after source edits.
  *Tags: plugins, marketplace, cache, portable-config, plugin-installation*
- Claude Code plugins use source-controlled code with per-machine marketplace registry and runtime cache; requires reinstall after source edits.
  *Tags: plugins, marketplace, cache, portable-config, plugin-installation*

<!-- CORTEX_MEMORY_END -->