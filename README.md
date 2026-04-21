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
- a Spotify app with a refresh token for your account

## Setup

1. Clone the repo.
2. Run `./install.sh`.
3. Fill in `~/.config/spotify-true-shuffle/config.env`:
   - `SPOTIFY_CLIENT_ID`
   - `SPOTIFY_CLIENT_SECRET`
   - `SPOTIFY_REFRESH_TOKEN`
4. Run `spotify_true_shuffle`.

The script stores the playlist id in `~/.local/state/spotify-true-shuffle/playlist_id` so later runs keep updating the same playlist.

## Optional config

- `SPOTIFY_PLAYLIST_NAME`
- `SPOTIFY_PLAYLIST_DESCRIPTION`
- `SPOTIFY_TRACK_COUNT`
- `SPOTIFY_TRUE_SHUFFLE_ENV_FILE`
- `SPOTIFY_TRUE_SHUFFLE_PLAYLIST_ID_FILE`

## Scheduling

Example `systemd --user` service:

```ini
[Unit]
Description=Refresh Spotify true shuffle playlist

[Service]
Type=oneshot
ExecStart=/path/to/spotify_true_shuffle
```

Run it from a timer, cron job, or manually.
