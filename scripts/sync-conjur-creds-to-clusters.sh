#!/usr/bin/env bash
set -euo pipefail

# Alias for legacy script name (kept for backward compatibility).
exec "$(dirname "$0")/sync-conjur-creds-to-spokes.sh" "$@"

