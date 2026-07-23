#!/usr/bin/env bash
#
# soundcloud-sync.sh
#
# Polls a SoundCloud artist's page for new tracks, downloads any that aren't
# already in the archive, drops them into your Navidrome music folder, and
# triggers a rescan. Meant to be run periodically via cron.
#
# Requirements:
#   - yt-dlp   (pip install -U yt-dlp   or  brew install yt-dlp)
#   - ffmpeg   (for audio extraction / tagging)
#   - curl, jq (for the Navidrome API call)
#
# --------------------------------------------------------------------------
set -euo pipefail

### ---- CONFIG (via environment variables) ----

SOUNDCLOUD_URL="${SOUNDCLOUD_URL:-https://soundcloud.com/ARTIST_NAME/tracks}"
MUSIC_DIR="${MUSIC_DIR:-/music}"
STATE_DIR="${STATE_DIR:-/state}"
NAVIDROME_URL="${NAVIDROME_URL:-http://localhost:4533}"
NAVIDROME_USER="${NAVIDROME_USER:-admin}"
NAVIDROME_PASS="${NAVIDROME_PASS:-changeme}"
TITLE_FILTER="${TITLE_FILTER:-}"
DATE_AFTER="${DATE_AFTER:-}"

### ---- END CONFIG ----

mkdir -p "$MUSIC_DIR" "$STATE_DIR"
ARCHIVE_FILE="$STATE_DIR/downloaded.txt"
LOG_FILE="$STATE_DIR/sync.log"
CACHE_DIR="$STATE_DIR/cache"
LOCK_FILE="$STATE_DIR/sync.lock"

# Acquire an exclusive non-blocking lock. If another instance is still running
# (e.g. a long initial sync) this run exits cleanly rather than racing on the
# download archive.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[$(date -Is)] Sync already running, skipping this run." >> "$LOG_FILE"
  exit 0
fi

echo "[$(date -Is)] Checking for new tracks..." >> "$LOG_FILE"

# Download any tracks not already in the archive.
# --download-archive tracks IDs across runs so re-runs are cheap no-ops
# unless there's genuinely something new.
NEW_COUNT_BEFORE=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)

if [ -n "$TITLE_FILTER" ]; then
  # All matched tracks share one folder; disc number differentiates episodes.
  # e.g. /music/Above & Beyond/Group Therapy/Group Therapy 686 (...).m4a
  OUTPUT_TEMPLATE="$MUSIC_DIR/%(uploader)s/$TITLE_FILTER/%(title)s.%(ext)s"
else
  OUTPUT_TEMPLATE="$MUSIC_DIR/%(uploader)s/%(title)s.%(ext)s"
fi

YTDLP_ARGS=(
  --extract-audio
  --embed-metadata
  --embed-thumbnail
  --cache-dir "$CACHE_DIR"
  --download-archive "$ARCHIVE_FILE"
  --output "$OUTPUT_TEMPLATE"
  --playlist-reverse
  --no-overwrites
  --ignore-errors
)

if [ -n "$DATE_AFTER" ]; then
  YTDLP_ARGS+=(--dateafter "$DATE_AFTER")
fi

if [ -n "$TITLE_FILTER" ]; then
  YTDLP_ARGS+=(
    --match-filter "title*=$TITLE_FILTER"
    --parse-metadata "${TITLE_FILTER}:%(meta_album)s"
    --parse-metadata "%(title)s:${TITLE_FILTER} (?P<meta_disc>\d+)"
  )
else
  YTDLP_ARGS+=(--parse-metadata "%(uploader)s:%(meta_album)s")
fi

yt-dlp "${YTDLP_ARGS[@]}" "$SOUNDCLOUD_URL" >> "$LOG_FILE" 2>&1

NEW_COUNT_AFTER=$(wc -l < "$ARCHIVE_FILE" 2>/dev/null || echo 0)
NEW_TRACKS=$((NEW_COUNT_AFTER - NEW_COUNT_BEFORE))

echo "[$(date -Is)] Done. New tracks this run: $NEW_TRACKS" >> "$LOG_FILE"

# Only bother pinging Navidrome if something actually changed.
if [ "$NEW_TRACKS" -gt 0 ]; then
  echo "[$(date -Is)] Triggering Navidrome scan..." >> "$LOG_FILE"

  TOKEN=$(curl -s -X POST "$NAVIDROME_URL/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$NAVIDROME_USER\",\"password\":\"$NAVIDROME_PASS\"}" \
    | jq -r '.token')

  curl -s -X POST "$NAVIDROME_URL/api/scan" \
    -H "x-nd-authorization: Bearer $TOKEN" >> "$LOG_FILE" 2>&1

  echo "[$(date -Is)] Scan triggered." >> "$LOG_FILE"
fi
