# SoundcloudSync

Polls a SoundCloud artist page or YouTube playlist for new tracks, downloads them into an [Audiobookshelf](https://www.audiobookshelf.org/) library, and triggers a rescan. Runs on a cron schedule inside a Docker container, designed for deployment on Unraid via Portainer.

## How it works

On each run, `yt-dlp` checks the configured URL for tracks not already in the download archive. New tracks are downloaded, tagged with metadata and cover art, and written to the music directory. If anything new was downloaded, the Audiobookshelf API is called to trigger an immediate library rescan.

The download archive persists between runs so repeat runs are cheap no-ops unless there is genuinely something new.

### Chapter splitting (`SPLIT_CHAPTERS`)

When `SPLIT_CHAPTERS` is set, each download is split into one audio file per chapter using embedded timestamps — useful for YouTube DJ mixes where each chapter is a song. The output is structured so that Audiobookshelf's **Book library** type treats each episode as one book with the tracks as its chapters:

```
/music/
  Above & Beyond/
    Group Therapy/
      Group Therapy 686 with Above & Beyond and Michael Cassette/
        cover.jpg
        01 - Intro.webm
        02 - Simon Gregory - Keep Moving On (Anjunabeats).webm
        ...
```

Set up your Audiobookshelf library as type **Books** (not Podcasts) pointing at the music directory.

## Deploying on Unraid (Portainer Stacks)

1. Push this repository to GitHub (or any git host Portainer can reach)
2. In Portainer: **Stacks → Add stack → Repository**
3. Set the repository URL and branch, compose file path: `docker-compose.yml`
4. Add the following environment variables in the Portainer UI:

| Variable | Description | Default |
|---|---|---|
| `SOUNDCLOUD_URL` | SoundCloud artist page or YouTube playlist URL | — |
| `AUDIOBOOKSHELF_URL` | Audiobookshelf base URL | `http://localhost:13378` |
| `AUDIOBOOKSHELF_TOKEN` | Audiobookshelf API token (Settings → Users → your user) | — |
| `AUDIOBOOKSHELF_LIBRARY_ID` | Library ID to scan after new downloads | — |
| `MUSIC_PATH` | Host path to mount as `/music` (your Audiobookshelf library folder) | `/mnt/user/music/SoundCloud` |
| `STATE_PATH` | Host path to mount as `/state` (persistent state) | `/mnt/user/appdata/soundcloud-sync` |
| `PUID` | UID to run as | `99` (Unraid `nobody`) |
| `PGID` | GID to run as | `100` (Unraid `users`) |
| `UMASK` | File creation mask | `022` |
| `CRON_SCHEDULE` | Cron expression for sync frequency | `0 */6 * * *` (every 6 hours) |
| `TITLE_FILTER` | Only download tracks whose title contains this substring; also used as the subfolder name. Leave unset to download all tracks. | — |
| `DATE_AFTER` | Only download tracks uploaded after this date (`20240101`, `today-1year`, etc.). Leave unset for no limit. | — |
| `SPLIT_CHAPTERS` | Set to any non-empty value to split each download into one file per chapter. See above. | — |
| `PLAYLIST_REVERSE` | Set to any non-empty value to process the playlist oldest-first. | — |

5. Click **Deploy the stack**

The container runs an initial sync immediately on startup, then continues on the cron schedule.

> **Note:** Portainer's stack-level environment variables use compose variable substitution — they replace `${VAR}` placeholders in the compose file. Setting them in the Portainer UI is the correct way to configure this container; do not edit `docker-compose.yml` directly.

### Finding your Audiobookshelf library ID

In Audiobookshelf: **Settings → Libraries → (your library)** — the ID appears in the URL (`/config/libraries/<ID>`).

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
- A running [Audiobookshelf](https://www.audiobookshelf.org/) instance accessible from the container
