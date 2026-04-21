#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/spotify-true-shuffle"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/spotify-true-shuffle"
TARGET_LINK="${BIN_DIR}/spotify_true_shuffle"
CONFIG_FILE="${CONFIG_DIR}/config.env"
EXAMPLE_FILE="${REPO_DIR}/config.env.example"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$STATE_DIR"
ln -sfn "${REPO_DIR}/spotify_true_shuffle" "$TARGET_LINK"

if [[ ! -f "$CONFIG_FILE" ]]; then
  cp "$EXAMPLE_FILE" "$CONFIG_FILE"
  printf 'Created %s\n' "$CONFIG_FILE"
else
  printf 'Keeping existing %s\n' "$CONFIG_FILE"
fi

printf 'Linked %s -> %s\n' "$TARGET_LINK" "${REPO_DIR}/spotify_true_shuffle"
printf 'Next: edit %s and then run spotify_true_shuffle\n' "$CONFIG_FILE"
