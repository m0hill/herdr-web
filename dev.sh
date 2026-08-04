#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v herdr >/dev/null 2>&1; then
  printf 'herdr-web: herdr is not available in PATH\n' >&2
  exit 1
fi

(
  cd web
  bun install --frozen-lockfile
  bun run build
)

exec zig build run -- "$@"
