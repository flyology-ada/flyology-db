#!/bin/sh
set -eu

if [ -n "${ALR:-}" ] && [ -x "$ALR" ]; then
  printf '%s\n' "$ALR"
elif command -v alr >/dev/null 2>&1; then
  command -v alr
elif [ -x "$HOME/alr" ]; then
  printf '%s\n' "$HOME/alr"
else
  printf '%s\n' "Alire 2.1 or newer is required" >&2
  exit 127
fi
