#!/bin/bash
set -euo pipefail

# Only run in remote Claude Code environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

echo "=== Installing system dependencies ===" >&2

# Ensure gcc and zlib are present (required to build and test this C project)
if ! dpkg -l zlib1g-dev 2>/dev/null | grep -q "^ii"; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq gcc zlib1g-dev
fi

echo "=== System dependencies ready ===" >&2
