#!/usr/bin/env bash
# sync-submodules.sh
# Safe helper to initialize/sync/fetch submodules after .gitmodules changes.
# Usage: mods/sync-submodules.sh [--remote] [--jobs N] [--repo-root /path/to/repo]
# By default this updates submodules to the commits recorded in the superproject.
# Pass --remote to update submodules to the remote tracking branch instead.

set -euo pipefail
IFS=$'\n\t'

JOBS=4
REMOTE=false
REPO_ROOT=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --remote            Update submodules to their remote tracking branch (non-reproducible)
  --jobs N            Number of parallel jobs for fetching/cloning submodules (default: ${JOBS})
  --repo-root PATH    Path to the repository root (defaults to git rev-parse)
  -h, --help          Show this help and exit

Examples:
  # Initialize and update submodules to recorded commits (safe, reproducible)
  ./mods/sync-submodules.sh

  # Initialize and update submodules to remote branches (fetch latest)
  ./mods/sync-submodules.sh --remote --jobs 8

EOF
}

# parse args
while [[ ${#} -gt 0 ]]; do
  case "$1" in
    --remote) REMOTE=true; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

# Determine repo root if not provided
if [[ -z "$REPO_ROOT" ]]; then
  if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    :
  else
    REPO_ROOT="$(pwd)"
  fi
fi

echo "Repository root: $REPO_ROOT"
cd "$REPO_ROOT"

# Safety: make sure we're in a git repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "This directory is not a git repository: $REPO_ROOT" >&2
  exit 3
fi

# Fetch and pull (superproject)
echo "Fetching remotes for superproject..."
git fetch --all --prune

# Optional: attempt a fast-forward pull on current branch (non-destructive)
if git rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
  current_branch=$(git rev-parse --abbrev-ref HEAD)
  echo "Attempting fast-forward pull on branch: $current_branch"
  git pull --ff-only || echo "warning: pull failed or not fast-forward; continuing"
fi

# Ensure .gitmodules URLs are synchronized into .git/config
echo "Syncing .gitmodules -> .git/config (recursive)"
git submodule sync --recursive

# Initialize and fetch submodules
if [[ "$REMOTE" == "true" ]]; then
  echo "Initializing and updating submodules to remote tracking branches (--remote)"
  git submodule update --init --recursive --remote --jobs "$JOBS"
else
  echo "Initializing and updating submodules to recorded commits (reproducible)"
  git submodule update --init --recursive --jobs "$JOBS"
fi

# Show summary
echo "Submodule status:"
git submodule status --recursive

echo "Done. If submodules are private, ensure your SSH key or token is available in the environment."

# End
