# SoundcloudSync

Polls a SoundCloud artist's page for new tracks, downloads them as MP3s into a Navidrome music folder, and triggers a library rescan. Runs on a cron schedule inside a Docker container, designed for deployment on Unraid via Portainer.

## How it works

On each run, `yt-dlp` checks the configured SoundCloud URL for tracks not already in the download archive. New tracks are extracted to MP3, tagged with metadata and thumbnail, and written to the music directory. If anything new was downloaded, the Navidrome API is called to trigger an immediate rescan rather than waiting for the next scheduled one.

The download archive persists between runs so repeat runs are cheap no-ops unless there is genuinely something new.

## Deploying on Unraid (Portainer Stacks)

1. Push this repository to GitHub (or any git host Portainer can reach)
2. In Portainer: **Stacks → Add stack → Repository**
3. Set the repository URL and branch, compose file path: `docker-compose.yml`
4. Add the following environment variables in the Portainer UI:

| Variable | Description | Default |
|---|---|---|
| `SOUNDCLOUD_URL` | Artist tracks URL (e.g. `https://soundcloud.com/artist/tracks`) | — |
| `NAVIDROME_URL` | Navidrome base URL | `http://localhost:4533` |
| `NAVIDROME_USER` | Navidrome username | `admin` |
| `NAVIDROME_PASS` | Navidrome password | — |
| `MUSIC_PATH` | Host path to mount as `/music` (your Navidrome music folder) | `/mnt/user/music/SoundCloud` |
| `STATE_PATH` | Host path to mount as `/state` (persistent state) | `/mnt/user/appdata/soundcloud-sync` |
| `PUID` | UID to run as | `99` (Unraid `nobody`) |
| `PGID` | GID to run as | `100` (Unraid `users`) |
| `UMASK` | File creation mask | `022` |
| `CRON_SCHEDULE` | Cron expression for sync frequency | `0 */6 * * *` (every 6 hours) |
| `TITLE_FILTER` | Only download tracks whose title contains this substring; also used as the album name. Leave unset to download all tracks. | — |

5. Click **Deploy the stack**

The container runs an initial sync immediately on startup, then continues on the cron schedule.

> **Note:** Portainer's stack-level environment variables use compose variable substitution — they replace `${VAR}` placeholders in the compose file. Setting them in the Portainer UI is the correct way to configure this container; do not edit `docker-compose.yml` directly.

## Persistent state

Everything written by the container across restarts lives under `STATE_PATH` on the host:

| Path | Contents |
|---|---|
| `downloaded.txt` | yt-dlp download archive — prevents re-downloading tracks |
| `sync.log` | Timestamped log of every sync run |
| `cache/` | yt-dlp cache (SoundCloud client ID, etc.) |

## Finding your PUID / PGID

Run this in the Unraid terminal to find the IDs of the user that owns your media shares:

```sh
id nobody
```

The defaults (`99`/`100`) match Unraid's built-in `nobody`/`users`, which is correct for most setups.

## Requirements

- Docker (via Unraid's built-in Docker or a VM)
- Portainer for stack management
- A running [Navidrome](https://www.navidrome.org/) instance accessible from the container
