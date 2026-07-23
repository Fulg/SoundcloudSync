#!/usr/bin/env bash
#
# sync.sh
#
# Polls a SoundCloud artist page or YouTube playlist for new tracks, downloads
# any that aren't already in the archive, drops them into your Navidrome music
# folder, and triggers a rescan. Meant to be run periodically via cron.
#
# When SPLIT_CHAPTERS=true, each downloaded video is split into one audio file
# per chapter using embedded timestamps (useful for YouTube DJ mixes).
#
# Requirements:
#   - yt-dlp   (pip install -U yt-dlp   or  brew install yt-dlp)
#   - ffmpeg   (for audio extraction / tagging)
#   - curl, jq (for the Navidrome API call)
#
# --------------------------------------------------------------------------
set -euo pipefail

# Busybox crond strips the container environment. Source the config file written
# by the entrypoint so cron-fired runs have the same variables as the startup run.
[ -f /state/.env ] && . /state/.env

### ---- CONFIG (via environment variables) ----

SOUNDCLOUD_URL="${SOUNDCLOUD_URL:-https://soundcloud.com/ARTIST_NAME/tracks}"
MUSIC_DIR="${MUSIC_DIR:-/music}"
STATE_DIR="${STATE_DIR:-/state}"
NAVIDROME_URL="${NAVIDROME_URL:-http://localhost:4533}"
NAVIDROME_USER="${NAVIDROME_USER:-admin}"
NAVIDROME_PASS="${NAVIDROME_PASS:-changeme}"
TITLE_FILTER="${TITLE_FILTER:-}"
DATE_AFTER="${DATE_AFTER:-}"
SPLIT_CHAPTERS="${SPLIT_CHAPTERS:-}"
PLAYLIST_REVERSE="${PLAYLIST_REVERSE:-}"

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

if [ -n "$SPLIT_CHAPTERS" ]; then
  if [ -n "$TITLE_FILTER" ]; then
    # Intermediate download (deleted after splitting)
    OUTPUT_TEMPLATE="$MUSIC_DIR/%(uploader)s/$TITLE_FILTER/%(title)s/%(title)s.%(ext)s"
    # One file per chapter: /music/Above & Beyond/Group Therapy/Group Therapy 686 (...)/01 - Song Title.opus
    CHAPTER_TEMPLATE="$MUSIC_DIR/%(uploader)s/$TITLE_FILTER/%(title)s/%(section_number)02d - %(section_title)s.%(ext)s"
  else
    OUTPUT_TEMPLATE="$MUSIC_DIR/%(uploader)s/%(title)s/%(title)s.%(ext)s"
    CHAPTER_TEMPLATE="$MUSIC_DIR/%(uploader)s/%(title)s/%(section_number)02d - %(section_title)s.%(ext)s"
  fi
elif [ -n "$TITLE_FILTER" ]; then
  # e.g. /music/Above & Beyond/Group Therapy/Group Therapy 686 (...).m4a
  OUTPUT_TEMPLATE="$MUSIC_DIR/%(uploader)s/$TITLE_FILTER/%(title)s.%(ext)s"
else
  # e.g. /music/Above & Beyond/Some Track.m4a
  OUTPUT_TEMPLATE="$MUSIC_DIR/%(uploader)s/%(title)s.%(ext)s"
fi

YTDLP_ARGS=(
  --embed-metadata
  --cache-dir "$CACHE_DIR"
  --download-archive "$ARCHIVE_FILE"
  --output "$OUTPUT_TEMPLATE"
  --no-overwrites
  --ignore-errors
  --sleep-interval 2
)

if [ -n "$SPLIT_CHAPTERS" ]; then
  # Download audio-only directly — avoids the extract-audio/split-chapters ordering
  # issue where ffmpeg can't split a mutagen-modified .opus file back into .opus chapters.
  # --embed-thumbnail is excluded: yt-dlp's thumbnail embedder does not support .webm.
  YTDLP_ARGS+=(--format "bestaudio")
else
  YTDLP_ARGS+=(--extract-audio --embed-thumbnail)
fi

if [ -n "$PLAYLIST_REVERSE" ]; then
  YTDLP_ARGS+=(--playlist-reverse)
fi

if [ -n "$DATE_AFTER" ]; then
  YTDLP_ARGS+=(--dateafter "$DATE_AFTER")
fi

if [ -n "$SPLIT_CHAPTERS" ]; then
  # Write a per-episode helper that yt-dlp runs via --exec after_video, i.e.
  # immediately after each video is split — not after the whole playlist.
  # It fixes title/track metadata (yt-dlp embeds the episode title in every
  # chapter file) and deletes the intermediate file that yt-dlp leaves behind.
  FIX_SCRIPT="$STATE_DIR/fix-chapters.sh"
  cat > "$FIX_SCRIPT" << 'FIXEOF'
#!/usr/bin/env bash
intermediate="$1"
[ -f "$intermediate" ] || exit 0
dir=$(dirname "$intermediate")
dir_name=$(basename "$dir")
stem=$(basename "${intermediate%.*}")
ext="${intermediate##*.}"
[ "$stem" = "$dir_name" ] || exit 0
while IFS= read -r -d '' fpath; do
  fstem=$(basename "${fpath%.*}")
  [ "$fstem" = "$dir_name" ] && continue
  if [[ "$fstem" =~ ^([0-9][0-9])\ -\ (.+)$ ]]; then
    track=$((10#${BASH_REMATCH[1]}))
    title="${BASH_REMATCH[2]}"
    tmp="${fpath}.tmp.${ext}"
    if ffmpeg -y -loglevel error -i "$fpath" -map 0 -c copy \
          -metadata title="$title" -metadata track="$track" "$tmp" 2>&1; then
      mv "$tmp" "$fpath"
    else
      rm -f "$tmp"
    fi
  fi
done < <(find "$dir" -maxdepth 1 -type f -name "*.${ext}" -print0)
rm -f "$intermediate"
FIXEOF
  chmod +x "$FIX_SCRIPT"
  YTDLP_ARGS+=(
    --split-chapters
    --output "chapter:$CHAPTER_TEMPLATE"
    --exec "after_video:bash $FIX_SCRIPT {}"
  )
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

yt-dlp "${YTDLP_ARGS[@]}" "$SOUNDCLOUD_URL" >> "$LOG_FILE" 2>&1 || true

# When splitting chapters, yt-dlp leaves the intermediate file in place and
# embeds the episode title in all chapter files instead of the chapter title.
# Fix both by using the intermediate file as a trigger: it exists iff the
# episode was just downloaded and not yet post-processed. Re-mux each chapter
# with the correct title and track number (parsed from the filename), then
# delete the intermediate so subsequent runs skip this episode.
if [ -n "$SPLIT_CHAPTERS" ]; then
  while IFS= read -r -d '' intermediate; do
    dir=$(dirname "$intermediate")
    dir_name=$(basename "$dir")
    ext="${intermediate##*.}"
    echo "[$(date -Is)] Fixing chapters in: $dir_name" >> "$LOG_FILE"
    while IFS= read -r -d '' fpath; do
      stem=$(basename "${fpath%.*}")
      [ "$stem" = "$dir_name" ] && continue
      if [[ "$stem" =~ ^([0-9]{2})\ -\ (.+)$ ]]; then
        track=$((10#${BASH_REMATCH[1]}))
        title="${BASH_REMATCH[2]}"
        tmp="${fpath}.tmp.${ext}"
        if ffmpeg -y -loglevel error -i "$fpath" -map 0 -c copy \
              -metadata title="$title" -metadata track="$track" "$tmp" 2>>"$LOG_FILE"; then
          mv "$tmp" "$fpath"
          echo "[$(date -Is)] Fixed: track=$track title=$title" >> "$LOG_FILE"
        else
          rm -f "$tmp"
        fi
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name "*.${ext}" -print0)
    rm -f "$intermediate"
    echo "[$(date -Is)] Removed intermediate: $dir_name.$ext" >> "$LOG_FILE"
  done < <(
    while IFS= read -r -d '' f; do
      s=$(basename "${f%.*}")
      d=$(basename "$(dirname "$f")")
      [ "$s" = "$d" ] && printf '%s\0' "$f"
    done < <(find "$MUSIC_DIR" -type f \( -name "*.webm" -o -name "*.opus" -o -name "*.m4a" \) -print0)
  )
fi

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
