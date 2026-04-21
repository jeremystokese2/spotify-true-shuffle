#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/spotify-true-shuffle"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/spotify-true-shuffle"
SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
TARGET_LINK="${BIN_DIR}/spotify_true_shuffle"
CONFIG_FILE="${CONFIG_DIR}/config.env"
EXAMPLE_FILE="${REPO_DIR}/config.env.example"
INSTALL_SYSTEMD="${INSTALL_SYSTEMD:-1}"
INSTALL_FETCH_REFRESH_TOKEN="${INSTALL_FETCH_REFRESH_TOKEN:-1}"
SERVICE_FILE="${SYSTEMD_DIR}/spotify-true-shuffle.service"
TIMER_FILE="${SYSTEMD_DIR}/spotify-true-shuffle.timer"
DEFAULT_REDIRECT_URI="http://127.0.0.1:3000/callback"

print_banner() {
  printf '\n'
  printf '  ____             _   _  __       ____  _            __  __ _      _ _ _\n'
  printf ' / ___| _ __   ___ | |_(_)/ _|_   _/ ___|| |__  _   _ / _|/ _| | ___| | | |\n'
  printf ' \___ \|  _ \\ / _ \\| __| | |_| | | \\___ \\|  _ \\| | | | |_| |_| |/ _ \\ | | |\n'
  printf '  ___) | |_) | (_) | |_| |  _| |_| |___) | | | | |_| |  _|  _| |  __/_|_|_|\n'
  printf ' |____/| .__/ \\___/ \\__|_|_|  \\__, |____/|_| |_|\\__,_|_| |_| |_|\\___(_|_|_)\n'
  printf '       |_|                     |___/\n'
}

is_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == your_* ]]
}

shell_quote() {
  printf '%q' "$1"
}

upsert_config() {
  local key="$1"
  local value="$2"
  local tmp_file
  tmp_file="$(mktemp)"

  if grep -q "^${key}=" "$CONFIG_FILE"; then
    awk -v key="$key" -v value="$value" 'BEGIN { updated = 0 } $0 ~ ("^" key "=") { print key "=" value; updated = 1; next } { print } END { if (!updated) print key "=" value }' "$CONFIG_FILE" > "$tmp_file"
  else
    cat "$CONFIG_FILE" > "$tmp_file"
    printf '%s=%s\n' "$key" "$value" >> "$tmp_file"
  fi

  mv "$tmp_file" "$CONFIG_FILE"
}

config_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$CONFIG_FILE" | tail -n 1
}

maybe_run_initial_refresh() {
  local client_id client_secret refresh_token run_output playlist_id liked_tracks used_tracks

  client_id="$(config_value SPOTIFY_CLIENT_ID)"
  client_secret="$(config_value SPOTIFY_CLIENT_SECRET)"
  refresh_token="$(config_value SPOTIFY_REFRESH_TOKEN)"

  if is_placeholder "$client_id" || is_placeholder "$client_secret" || is_placeholder "$refresh_token"; then
    printf 'Spotify setup saved, but the initial playlist refresh was skipped because the credentials are incomplete.\n'
    return
  fi

  printf 'Running the first playlist refresh...\n'
  if ! run_output="$($TARGET_LINK 2>&1)"; then
    printf 'The installer finished, but the first playlist refresh failed:\n%s\n' "$run_output" >&2
    return 1
  fi

  playlist_id="$(printf '%s\n' "$run_output" | awk -F': ' '/^Playlist ID:/ { print $2 }')"
  liked_tracks="$(printf '%s\n' "$run_output" | awk -F': ' '/^Liked tracks found:/ { print $2 }')"
  used_tracks="$(printf '%s\n' "$run_output" | awk -F': ' '/^Tracks placed into playlist:/ { print $2 }')"

  printf 'Initial playlist refresh complete.\n'
  if [[ -n "$playlist_id" ]]; then
    printf 'Playlist ID: %s\n' "$playlist_id"
  fi
  if [[ -n "$liked_tracks" && -n "$used_tracks" ]]; then
    printf 'Picked %s tracks from %s liked songs.\n' "$used_tracks" "$liked_tracks"
  fi
}

maybe_fetch_refresh_token() {
  local client_id client_secret refresh_token redirect_uri auth_url auth_code token_response new_refresh_token code_file server_pid

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  client_id="${SPOTIFY_CLIENT_ID:-}"
  client_secret="${SPOTIFY_CLIENT_SECRET:-}"
  refresh_token="${SPOTIFY_REFRESH_TOKEN:-}"
  redirect_uri="${SPOTIFY_REDIRECT_URI:-$DEFAULT_REDIRECT_URI}"

  if [[ "$INSTALL_FETCH_REFRESH_TOKEN" != "1" ]]; then
    printf 'Skipping refresh token setup because INSTALL_FETCH_REFRESH_TOKEN=%s\n' "$INSTALL_FETCH_REFRESH_TOKEN"
    return
  fi

  if ! is_placeholder "$refresh_token"; then
    printf 'Keeping existing Spotify refresh token\n'
    return
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'Skipping refresh token setup in non-interactive mode\n'
    return
  fi

  if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
    printf 'Refresh token setup requires python3, curl, jq, and base64\n' >&2
    return
  fi

  if is_placeholder "$client_id"; then
    printf 'Spotify Client ID: '
    IFS= read -r client_id
    if is_placeholder "$client_id"; then
      printf 'Client ID is required\n' >&2
      return
    fi
    upsert_config SPOTIFY_CLIENT_ID "$(shell_quote "$client_id")"
  fi

  if is_placeholder "$client_secret"; then
    printf 'Spotify Client Secret: '
    stty -echo
    IFS= read -r client_secret
    stty echo
    printf '\n'
    if is_placeholder "$client_secret"; then
      printf 'Client secret is required\n' >&2
      return
    fi
    upsert_config SPOTIFY_CLIENT_SECRET "$(shell_quote "$client_secret")"
  fi

  if [[ "$redirect_uri" != "$DEFAULT_REDIRECT_URI" ]]; then
    printf 'Using configured redirect URI: %s\n' "$redirect_uri"
  else
    printf 'Using redirect URI: %s\n' "$redirect_uri"
  fi
  printf 'Make sure this exact callback URL is registered in your Spotify app before you continue.\n'
  printf 'Press Enter to continue... '
  IFS= read -r _

  auth_url="$(python3 - "$client_id" "$redirect_uri" <<'PY'
import sys
from urllib.parse import urlencode

client_id = sys.argv[1]
redirect_uri = sys.argv[2]
params = {
    'client_id': client_id,
    'response_type': 'code',
    'redirect_uri': redirect_uri,
    'scope': 'user-library-read playlist-modify-private',
}
print('https://accounts.spotify.com/authorize?' + urlencode(params))
PY
  )"

  printf 'Open this URL, approve access, and wait for the local callback:\n%s\n' "$auth_url"

  code_file="$(mktemp)"
  trap 'rm -f "$code_file"' RETURN

  printf 'Waiting for Spotify callback on %s\n' "$redirect_uri"
  python3 - "$redirect_uri" "$code_file" <<'PY' >/dev/null &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

redirect_uri = sys.argv[1]
code_file = sys.argv[2]
parsed = urlparse(redirect_uri)
host = parsed.hostname or '127.0.0.1'
port = parsed.port or 80
path = parsed.path or '/'

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed_request = urlparse(self.path)
        if parsed_request.path != path:
            self.send_response(404)
            self.end_headers()
            return

        query = parse_qs(parsed_request.query)
        code = query.get('code', [''])[0]
        error = query.get('error', [''])[0]
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        if code:
            self.wfile.write(b'<html><body><h1>Spotify authorisation complete</h1><p>You can close this window.</p></body></html>')
            with open(code_file, 'w', encoding='utf-8') as handle:
                handle.write(code)
        else:
            self.wfile.write(b'<html><body><h1>Spotify authorisation failed</h1><p>No code received.</p></body></html>')
            if error:
                with open(code_file, 'w', encoding='utf-8') as handle:
                    handle.write('ERROR:' + error)

    def log_message(self, format, *args):
        return

server = HTTPServer((host, port), Handler)
server.handle_request()
PY
  server_pid=$!

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$auth_url" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "$auth_url" >/dev/null 2>&1 || true
  fi

  while [[ ! -s "$code_file" ]]; do
    sleep 1
  done

  wait "$server_pid"
  auth_code="$(<"$code_file")"
  rm -f "$code_file"
  trap - RETURN

  if [[ "$auth_code" == ERROR:* ]]; then
    printf 'Spotify authorisation failed: %s\n' "${auth_code#ERROR:}" >&2
    return
  fi

  token_response="$(curl -fsS -X POST "https://accounts.spotify.com/api/token" \
    -H "Authorization: Basic $(printf '%s' "${client_id}:${client_secret}" | base64 | tr -d '\n')" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=${auth_code}" \
    --data-urlencode "redirect_uri=${redirect_uri}")"

  new_refresh_token="$(jq -r '.refresh_token // empty' <<<"$token_response")"
  if [[ -z "$new_refresh_token" ]]; then
    printf 'Spotify did not return a refresh token\n' >&2
    return
  fi

  upsert_config SPOTIFY_REFRESH_TOKEN "$new_refresh_token"
  printf 'Stored Spotify refresh token in %s\n' "$CONFIG_FILE"
}

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$STATE_DIR"
ln -sfn "${REPO_DIR}/spotify_true_shuffle" "$TARGET_LINK"

if [[ ! -f "$CONFIG_FILE" ]]; then
  cp "$EXAMPLE_FILE" "$CONFIG_FILE"
  printf 'Created local config at %s\n' "$CONFIG_FILE"
else
  printf 'Using existing config at %s\n' "$CONFIG_FILE"
fi

printf 'Linked %s\n' "$TARGET_LINK"

maybe_fetch_refresh_token

if [[ "$INSTALL_SYSTEMD" == "1" ]]; then
  mkdir -p "$SYSTEMD_DIR"

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Refresh Spotify true shuffle playlist

[Service]
Type=oneshot
ExecStart=${TARGET_LINK}
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Spotify true shuffle daily

[Timer]
OnCalendar=*-*-* 07:00:00
Persistent=true
Unit=spotify-true-shuffle.service

[Install]
WantedBy=timers.target
EOF

  printf 'Installed user service and timer.\n'

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user daemon-reload && systemctl --user enable --now spotify-true-shuffle.timer; then
      printf 'Enabled daily timer at 07:00.\n'
    else
      printf 'systemctl --user is available but enable/start failed; configure %s manually if needed\n' "$TIMER_FILE"
    fi
  else
    printf 'systemctl not found; enable %s manually if needed\n' "$TIMER_FILE"
  fi
else
  printf 'Skipping systemd setup because INSTALL_SYSTEMD=%s\n' "$INSTALL_SYSTEMD"
fi

maybe_run_initial_refresh
print_banner
printf 'spotify_true_shuffle is installed and ready.\n'
