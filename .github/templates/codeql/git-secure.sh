#!/usr/bin/env bash
# CodeQL bypass prevention wrapper for bash/zsh
# Strips --no-verify and -n flags from git commit commands

# command -v is a shell builtin (no process spawns); which -a | grep | head spawns 3 processes per invocation
REAL_GIT=$(command -v git)
if [ -z "$REAL_GIT" ]; then
  REAL_GIT=/usr/bin/git
fi

ARGS=()
STRIPPED=false
IS_COMMIT=false

for arg in "$@"; do
  if [ "$arg" = "commit" ] && [ "$IS_COMMIT" = false ]; then
    IS_COMMIT=true
    ARGS+=("$arg")
  elif [ "$IS_COMMIT" = true ] && [ "$arg" = "--no-verify" ]; then
    STRIPPED=true
  elif [ "$IS_COMMIT" = true ] && [[ "$arg" =~ ^-[a-zA-Z]*n[a-zA-Z]*$ ]]; then
    # Combined short flags containing -n (e.g., -an, -nm, -anm)
    # Use bash parameter expansion (no process spawns) instead of echo | sed
    CLEANED="${arg//n/}"
    STRIPPED=true
    if [ "$CLEANED" != "-" ]; then
      ARGS+=("$CLEANED")  # Keep remaining flags (e.g., -an -> -a)
    fi
  else
    ARGS+=("$arg")
  fi
done

if [ "$STRIPPED" = true ]; then
  echo "[WARN] --no-verify is disabled. CodeQL security scan cannot be bypassed."
fi

"$REAL_GIT" "${ARGS[@]}"
exit $?
