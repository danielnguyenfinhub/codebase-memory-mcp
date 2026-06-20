# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**codebase-memory-mcp** is a Model Context Protocol (MCP) server that provides code intelligence for AI coding agents. It indexes codebases into a persistent knowledge graph using tree-sitter AST analysis across 158 languages, then answers structural queries (finding functions, tracing calls, detecting dead code, etc.) in milliseconds. Shipped as a single static C binary with zero runtime dependencies.

**Key facts:**
- Pure C (rewritten from Go in v0.5.0) with ~22K lines in `internal/cbm/`
- Tree-sitter grammars for 158 languages vendored and compiled into the binary
- Runs as an MCP server over stdin/stdout (JSON-RPC 2.0)
- Optional HTTP UI for graph visualization at localhost:9749
- Hybrid LSP semantic resolution for Python, TypeScript, Go, C/C++, Java, Rust, and others

## Architecture

### High-Level Flow

1. **Indexing Pipeline** (`src/pipeline/`)
   - Accepts a directory path
   - Stages: parse (tree-sitter), extract (semantic), discover (routes/patterns), analyze (usages/calls)
   - Outputs: typed graph nodes (Function, Class, HttpRoute, etc.) and edges (CALLS, DEFINES, IMPORTS, etc.)
   - Results persisted to SQLite graph store

2. **Graph Store** (`src/store/`)
   - SQLite-backed typed property graph
   - Schema: `nodes` table (id, type, data), `edges` table (src, dst, type)
   - LZ4 compression for large values, in-memory database for speed
   - Cleanup: memory released after indexing completes

3. **MCP Server** (`src/mcp/`)
   - Implements JSON-RPC 2.0 protocol
   - Routes tool calls (e.g., `search_functions`, `trace_calls`, `find_dead_code`)
   - Reads from graph store, streams results
   - Runs on stdin/stdout (default) or as CLI tool

4. **Watcher** (`src/watcher/`)
   - Background thread that polls git working tree
   - Detects file changes, triggers re-indexing of affected modules
   - Keeps graph in sync without full re-index

5. **HTTP UI Server** (`src/ui/`)
   - Optional background thread (enabled via `--ui=true`)
   - Serves 3D graph visualization at localhost:9749
   - Embedded React app (built from `graph-ui/`)

6. **CLI Mode** (`src/cli/`)
   - Tool invocation without MCP protocol: `codebase-memory-mcp cli <tool> <json>`
   - Useful for testing and integration

### Module Responsibilities

| Module | Purpose |
|--------|---------|
| `src/foundation/` | Core data structures, logging, memory, platform abstractions |
| `src/semantic/` | Hybrid LSP: parse language-specific syntax into typed graph nodes |
| `src/discover/` | Pattern discovery (HTTP routes in Fastapi/Flask/Express, Kubernetes manifests, etc.) |
| `src/traces/` | Call chain tracing, data flow analysis |
| `src/cypher/` | Cypher-like query language for custom graph traversal |
| `src/graph_buffer/` | In-memory buffering of graph edges before commit to SQLite |
| `src/simhash/` | Similarity hashing for duplicate detection |
| `internal/cbm/` | Tree-sitter grammar compilation, low-level AST extraction, language specs |

### Key Design Patterns

- **Memory pool allocation**: All allocations bound to a single `cbm_alloc_t`, released on completion
- **Signal-safe shutdown**: `request_shutdown()` is async-signal-safe; safe to call from signal handlers
- **Atomic guards**: Pipeline locks and shutdown flags use atomics to prevent races
- **Vendored tree-sitter**: All 158 grammar files built into binary; no external dependencies
- **Stream-based results**: MCP tool handlers stream results to avoid buffering large graphs in RAM

## Build & Development Commands

### Build

```bash
# Production binary (optimized, no sanitizers)
scripts/build.sh

# Binary output to:
build/c/codebase-memory-mcp
```

### Testing

```bash
# Full test suite (all ~2040 tests, ASan + UBSan)
scripts/test.sh

# Foundation tests only (fast, <5s)
make -f Makefile.cbm test-foundation

# Thread sanitizer build
make -f Makefile.cbm test-tsan

# Single test file (e.g., MCP protocol tests)
make -f Makefile.cbm test TESTS="test_mcp.c"

# Verbose output
make -f Makefile.cbm test VERBOSE=1
```

### Linting & Formatting

```bash
# Run all linters (clang-tidy, cppcheck, clang-format)
scripts/lint.sh

# Auto-fix formatting
clang-format -i src/**/*.{c,h} internal/cbm/*.h
```

### Security Audit

```bash
# Run 8-layer security checks (static audit, binary scans, fuzz testing, etc.)
make -f Makefile.cbm security
```

### Development Workflow

```bash
# 1. Clone and configure git hooks for pre-commit checks
git config core.hooksPath scripts/hooks

# 2. Make changes and test
scripts/test.sh

# 3. Lint and fix
scripts/lint.sh
clang-format -i <modified_files>

# 4. Commit (pre-commit hook runs, blocks if checks fail)
git add .
git commit -m "..."

# 5. Clean build artifacts
make -f Makefile.cbm clean-c
```

## Testing Strategy

Tests live in `tests/` and are organized by module:

- **`test_pipeline.c`** — End-to-end indexing (parse, extract, discover, analyze stages)
- **`test_httplink.c`** — HTTP route extraction and cross-service linking
- **`test_mcp.c`** — MCP protocol (tool calls, streaming results, error handling)
- **`test_store_*.c`** — Graph store (SQLite insert/query, compression, schema)
- **`test_semantic_*.c`** — Language-specific extraction (Python, TypeScript, Go, etc.)

**Running a single test:**
```bash
make -f Makefile.cbm test TESTS="test_pipeline.c"
```

Tests compile with Address Sanitizer (ASan) and Undefined Behavior Sanitizer (UBSan) to catch memory errors and undefined behavior. Thread Sanitizer (TSan) is optional (`test-tsan`).

## Code Style & Conventions

- **C11 standard**: C11 features allowed; no C++
- **Naming**: snake_case for functions/variables, SCREAMING_SNAKE_CASE for macros
- **Struct prefix**: Functions operating on a struct are prefixed with the struct name (e.g., `cbm_store_*` for `cbm_store_t`)
- **Error handling**: Return status codes; use `cbm_log_error()` for diagnostics; avoid exceptions (C has none)
- **Includes**: Group by standard library, vendored, then internal; use `#include "path/to/file.h"` for internal
- **Macros**: Minimize; prefer static inline functions; upper-case only for constants and configuration
- **Comments**: Explain the "why", not the "what"; use `/* ... */` for blocks; avoid over-commenting obvious code

## Common Tasks

### Add a New MCP Tool

1. Define tool spec in `src/mcp/mcp.c:mcp_tools_init()`
2. Implement handler in `src/mcp/tools/` (e.g., `tool_search_functions.c`)
3. Add tests in `tests/test_mcp.c`
4. Rebuild and run tests: `make -f Makefile.cbm test`

### Index a New Codebase

```bash
codebase-memory-mcp cli initialize '{"rootPath":"/path/to/repo"}'
```

The pipeline auto-detects language, runs all stages, and populates the graph. Results are streamed as JSON events.

### Debug a Failing Test

```bash
# Run with sanitizer output
ASAN_OPTIONS=verbosity=1 make -f Makefile.cbm test TESTS="test_pipeline.c" VERBOSE=1

# Use gdb
gdb --args ./build/c/tests/test_pipeline arg1 arg2
```

### Modify Grammar or Language Support

Grammar files are in `internal/cbm/grammar_*.c` and compiled into the binary. Changes require:
1. Edit grammar in `internal/cbm/grammar_<lang>.c`
2. Update `internal/cbm/lang_specs.h` if language metadata changes
3. Rebuild: `scripts/build.sh`
4. Test: `make -f Makefile.cbm test`

## Key Files & Entry Points

- **`src/main.c`** — Entry point; signal handling, thread spawning, mode dispatch
- **`src/mcp/mcp.c`** — MCP server loop, tool routing, result streaming
- **`src/pipeline/pipeline.c`** — Indexing pipeline orchestration
- **`src/store/store.c`** — SQLite graph store API
- **`internal/cbm/cbm.h`** — Central header with allocator binding, version, config

## Dependencies & Vendoring

All dependencies are vendored in the binary:

- **tree-sitter** (`internal/cbm/vendored/ts_runtime/`) — Language parsing
- **SQLite3** (`internal/cbm/vendored/sqlite3/`) — Graph persistence
- **yyjson** (`internal/cbm/vendored/yyjson/`) — JSON parsing/generation
- **LZ4** (`internal/cbm/vendored/lz4/`) — Value compression
- **xxHash** (`internal/cbm/vendored/xxhash/`) — Fast hashing
- **libgit2** (optional, auto-detected via pkg-config) — Git history parsing

Missing libgit2? The build falls back to `popen("git log ...")` — slower but still functional.

## Performance Notes

- **Indexing speed**: ~500M LOC/min (optimized LZ4 + SQLite); Linux kernel (28M LOC, 75K files) in ~3 minutes
- **Query latency**: <1ms for graph traversals (in-memory SQLite)
- **Memory**: Released after indexing; graph stored compressively in SQLite
- **RAM usage during indexing**: Capped at 50% of system RAM (configurable via `MAIN_RAM_FRACTION`)

## Debugging & Diagnostics

Enable verbose logging:
```bash
CBM_DEBUG=1 ./build/c/codebase-memory-mcp
```

Check logs in `~/.codebase-memory-mcp/logs/` (if running as MCP server).

Use `--ui=true` to visualize the graph at localhost:9749 (useful for understanding structure of small repos).

## Platform Support

- **macOS** (arm64, amd64): Requires Xcode Command Line Tools (`xcode-select --install`)
- **Linux** (arm64, amd64): Requires gcc, zlib-dev (installed by session-start hook in remote Claude Code)
- **Windows** (amd64): Requires MSVC or MinGW; pre-built binary available

Local development on macOS/Linux works out of the box. Remote Claude Code sessions auto-install dependencies via `.claude/hooks/session-start.sh`.
