# spotify-true-shuffle

Refresh a Spotify playlist with a fresh random sample from your Liked Songs.

## What it does

- fetches all tracks from your Spotify Liked Songs
- picks a random subset
- replaces the target playlist contents with that selection
- reuses the same playlist id on future runs

## Requirements

- `bash`
- `curl`
- `jq`
- `shuf`
- a Spotify app for your account

## Setup

1. Clone the repo.
2. Run `./install.sh`.
3. If prompted, enter your Spotify `Client ID` and `Client Secret`.
4. Run `spotify_true_shuffle`.

The script stores the playlist id in `~/.local/state/spotify-true-shuffle/playlist_id` so later runs keep updating the same playlist.

By default `install.sh` also writes and enables a `systemd --user` timer for a daily 07:00 run.

## Create a Spotify app

1. Go to the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) and sign in.
2. Click `Create an app`.
3. Give it any name and description.
4. Add a redirect URI such as `http://127.0.0.1:3000/callback`.
5. Open the app settings and copy the `Client ID`.
6. Click `View client secret` and copy the `Client Secret`.

The installer assumes that exact callback URL is already registered in the Spotify app.

For this script, the app needs a user refresh token created via Spotify's Authorization Code flow, with these scopes:

- `user-library-read`
- `playlist-modify-private`

Spotify docs:

- [Getting started](https://developer.spotify.com/documentation/web-api/tutorials/getting-started)
- [Authorization Code flow](https://developer.spotify.com/documentation/web-api/tutorials/code-flow)
- [Refreshing tokens](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens)

## Get a refresh token

If `SPOTIFY_REFRESH_TOKEN` is missing, `./install.sh` can do the OAuth setup for you:

1. Run `./install.sh` in a terminal.
2. If the config does not already contain them, the installer prompts for `SPOTIFY_CLIENT_ID` and `SPOTIFY_CLIENT_SECRET` and saves them.
3. The installer assumes the Spotify app already allows `http://127.0.0.1:3000/callback`.
4. The installer starts a tiny local callback server, prints the Spotify authorisation URL, and opens it in your browser when possible.
5. After you approve access, the installer captures the authorisation code, exchanges it for tokens, and writes `SPOTIFY_REFRESH_TOKEN` into your config file.

You can also prefill `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, or `SPOTIFY_REDIRECT_URI` in `~/.config/spotify-true-shuffle/config.env` if you prefer.

Once you have the refresh token, the script handles access-token refresh automatically on later runs.

## Optional config

- `SPOTIFY_PLAYLIST_NAME`
- `SPOTIFY_PLAYLIST_DESCRIPTION`
- `SPOTIFY_TRACK_COUNT`
- `SPOTIFY_TRUE_SHUFFLE_ENV_FILE`
- `SPOTIFY_TRUE_SHUFFLE_PLAYLIST_ID_FILE`

## Scheduling

The installer writes these files:

- `~/.config/systemd/user/spotify-true-shuffle.service`
- `~/.config/systemd/user/spotify-true-shuffle.timer`

It then runs:

```bash
systemctl --user daemon-reload
systemctl --user enable --now spotify-true-shuffle.timer
```

To skip `systemd` setup:

```bash
INSTALL_SYSTEMD=0 ./install.sh
```

Installed service:

```ini
[Unit]
Description=Refresh Spotify true shuffle playlist

[Service]
Type=oneshot
ExecStart=%h/.local/bin/spotify_true_shuffle
```

Installed timer:

```ini
[Unit]
Description=Run Spotify true shuffle daily

[Timer]
OnCalendar=*-*-* 07:00:00
Persistent=true
Unit=spotify-true-shuffle.service

[Install]
WantedBy=timers.target
```

Run it from a timer, cron job, or manually.
