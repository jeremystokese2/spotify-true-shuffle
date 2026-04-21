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

is_placeholder() {
  local value="$1"
  [[ -z "$value" || "$value" == your_* ]]
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

maybe_fetch_refresh_token() {
  local client_id client_secret refresh_token redirect_uri auth_url auth_code token_response new_refresh_token

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  client_id="${SPOTIFY_CLIENT_ID:-}"
  client_secret="${SPOTIFY_CLIENT_SECRET:-}"
  refresh_token="${SPOTIFY_REFRESH_TOKEN:-}"
  redirect_uri="${SPOTIFY_REDIRECT_URI:-http://127.0.0.1:3000/callback}"

  if [[ "$INSTALL_FETCH_REFRESH_TOKEN" != "1" ]]; then
    printf 'Skipping refresh token setup because INSTALL_FETCH_REFRESH_TOKEN=%s\n' "$INSTALL_FETCH_REFRESH_TOKEN"
    return
  fi

  if ! is_placeholder "$refresh_token"; then
    printf 'Keeping existing Spotify refresh token\n'
    return
  fi

  if is_placeholder "$client_id" || is_placeholder "$client_secret"; then
    printf 'Set SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET in %s first\n' "$CONFIG_FILE"
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
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$auth_url" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "$auth_url" >/dev/null 2>&1 || true
  fi

  auth_code="$(python3 - "$redirect_uri" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

redirect_uri = sys.argv[1]
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
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.end_headers()
        if code:
            self.wfile.write(b'<html><body><h1>Spotify authorisation complete</h1><p>You can close this window.</p></body></html>')
            print(code)
        else:
            self.wfile.write(b'<html><body><h1>Spotify authorisation failed</h1><p>No code received.</p></body></html>')
        self.server.code = code

    def log_message(self, format, *args):
        return

server = HTTPServer((host, port), Handler)
server.handle_request()
if not getattr(server, 'code', ''):
    raise SystemExit(1)
PY
)"

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
  printf 'Created %s\n' "$CONFIG_FILE"
else
  printf 'Keeping existing %s\n' "$CONFIG_FILE"
fi

printf 'Linked %s -> %s\n' "$TARGET_LINK" "${REPO_DIR}/spotify_true_shuffle"

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

  printf 'Wrote %s\n' "$SERVICE_FILE"
  printf 'Wrote %s\n' "$TIMER_FILE"

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl --user daemon-reload && systemctl --user enable --now spotify-true-shuffle.timer; then
      printf 'Enabled spotify-true-shuffle.timer\n'
    else
      printf 'systemctl --user is available but enable/start failed; configure %s manually if needed\n' "$TIMER_FILE"
    fi
  else
    printf 'systemctl not found; enable %s manually if needed\n' "$TIMER_FILE"
  fi
else
  printf 'Skipping systemd setup because INSTALL_SYSTEMD=%s\n' "$INSTALL_SYSTEMD"
fi

printf 'Next: edit %s and then run spotify_true_shuffle\n' "$CONFIG_FILE"
