#!/usr/bin/env bash
#
# soundcloud-sync.sh
#
# Polls a SoundCloud artist page or YouTube playlist for new tracks, downloads
# any that aren't already in the archive, and triggers an Audiobookshelf rescan.
# Meant to be run periodically via cron.
#
# When SPLIT_CHAPTERS is set, each downloaded video is split into one audio file
# per chapter using embedded timestamps (useful for YouTube DJ mixes).
#
# Requirements:
#   - yt-dlp   (pip install -U yt-dlp   or  brew install yt-dlp)
#   - ffmpeg   (for audio extraction / tagging)
#   - curl     (for the Audiobookshelf API call)
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
AUDIOBOOKSHELF_URL="${AUDIOBOOKSHELF_URL:-http://localhost:13378}"
AUDIOBOOKSHELF_TOKEN="${AUDIOBOOKSHELF_TOKEN:-}"
AUDIOBOOKSHELF_LIBRARY_ID="${AUDIOBOOKSHELF_LIBRARY_ID:-}"
TITLE_FILTER="${TITLE_FILTER:-}"
DATE_AFTER="${DATE_AFTER:-}"
SPLIT_CHAPTERS="${SPLIT_CHAPTERS:-}"
PLAYLIST_REVERSE="${PLAYLIST_REVERSE:-}"

### ---- END CONFIG ----

mkdir -p "$MUSIC_DIR" "$STATE_DIR"
ARCHIVE_FILE="$STATE_DIR/downloaded.txt"
touch "$ARCHIVE_FILE"
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
NEW_COUNT_BEFORE=$(wc -l < "$ARCHIVE_FILE")

if [ -n "$SPLIT_CHAPTERS" ]; then
  if [ -n "$TITLE_FILTER" ]; then
    # Intermediate download (deleted after splitting)
    OUTPUT_TEMPLATE="$MUSIC_DIR/%(uploader)s/$TITLE_FILTER/%(title)s/%(title)s.%(ext)s"
    # One file per chapter: /music/Above & Beyond/Group Therapy/Group Therapy 686 (...)/01 - Song Title.webm
    CHAPTER_TEMPLATE="$MUSIC_DIR/%(uploader)s/$TITLE_FILTER/%(title)s/%(section_number)02d - %(section_title)s.%(ext)s"
    # cover.jpg in each episode folder — picked up by Audiobookshelf Book library as cover art
    THUMBNAIL_TEMPLATE="$MUSIC_DIR/%(uploader)s/$TITLE_FILTER/%(title)s/cover.%(ext)s"
  else
    OUTPUT_TEMPLATE="$MUSIC_DIR/%(uploader)s/%(title)s/%(title)s.%(ext)s"
    CHAPTER_TEMPLATE="$MUSIC_DIR/%(uploader)s/%(title)s/%(section_number)02d - %(section_title)s.%(ext)s"
    THUMBNAIL_TEMPLATE="$MUSIC_DIR/%(uploader)s/%(title)s/cover.%(ext)s"
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
  # Thumbnail is saved as cover.jpg alongside the chapter files rather than embedded
  # (WebM does not support embedded thumbnails via yt-dlp).
  YTDLP_ARGS+=(
    --format "bestaudio"
    --write-thumbnail
    --convert-thumbnails jpg
    --output "thumbnail:$THUMBNAIL_TEMPLATE"
  )
else
  YTDLP_ARGS+=(--extract-audio --embed-thumbnail)
fi

if [ -n "$PLAYLIST_REVERSE" ]; then
  YTDLP_ARGS+=(--playlist-reverse)
fi

if [ -n "$DATE_AFTER" ]; then
  YTDLP_ARGS+=(--dateafter "$DATE_AFTER")
  # In default (newest-first) order, the first rejection means all remaining
  # items are also too old — stop immediately instead of checking every one.
  # With PLAYLIST_REVERSE the oldest items come first, so this would fire
  # on the very first video and abort the run.
  [ -z "$PLAYLIST_REVERSE" ] && YTDLP_ARGS+=(--break-on-reject)
fi

if [ -n "$SPLIT_CHAPTERS" ]; then
  # Write a per-episode helper that yt-dlp runs via --exec after_video.
  # Rather than relying on {}, which yt-dlp may substitute with a chapter path
  # instead of the intermediate after FFmpegSplitChaptersPP runs, we pass
  # MUSIC_DIR and LOG_FILE explicitly and scan for orphaned intermediates.
  FIX_SCRIPT="$STATE_DIR/fix-chapters.sh"
  cat > "$FIX_SCRIPT" << 'FIXEOF'
#!/usr/bin/env bash
# Called by yt-dlp after each video is split into chapters.
# Scans music_dir for intermediate files (name == parent dir name), rewrites
# chapter metadata (title and track number), then deletes each intermediate.
music_dir="$1"
log_file="$2"
while IFS= read -r -d '' f; do
  s=$(basename "${f%.*}")
  d=$(basename "$(dirname "$f")")
  [ "$s" = "$d" ] || continue
  dir=$(dirname "$f")
  ext="${f##*.}"
  echo "[$(date -Is)] [fix-chapters] Processing: $s" >> "$log_file"
  while IFS= read -r -d '' chapter; do
    cstem=$(basename "${chapter%.*}")
    [ "$cstem" = "$s" ] && continue
    [[ "$cstem" =~ ^([0-9][0-9])\ -\ (.+)$ ]] || continue
    track=$((10#${BASH_REMATCH[1]}))
    title="${BASH_REMATCH[2]}"
    tmp="${chapter}.tmp.${ext}"
    if ffmpeg -y -loglevel error -i "$chapter" -map 0 -c copy \
          -metadata title="$title" -metadata track="$track" -metadata ALBUM="$s" "$tmp" >> "$log_file" 2>&1; then
      mv "$tmp" "$chapter"
      echo "[$(date -Is)] [fix-chapters] Fixed: track=$track title=$title" >> "$log_file"
    else
      rm -f "$tmp"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name "*.${ext}" -print0)
  rm -f "$f"
  echo "[$(date -Is)] [fix-chapters] Removed intermediate: $s.$ext" >> "$log_file"
done < <(find "$music_dir" -type f \( -name "*.webm" -o -name "*.opus" -o -name "*.m4a" \) -print0)
FIXEOF
  chmod +x "$FIX_SCRIPT"
  YTDLP_ARGS+=(
    --split-chapters
    --output "chapter:$CHAPTER_TEMPLATE"
    --exec "after_video:bash $FIX_SCRIPT $MUSIC_DIR $LOG_FILE"
  )
fi

if [ -n "$TITLE_FILTER" ]; then
  YTDLP_ARGS+=(
    --match-filter "title*=$TITLE_FILTER"
    --parse-metadata "%(title)s:%(meta_album)s"
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
              -metadata title="$title" -metadata track="$track" -metadata ALBUM="$dir_name" "$tmp" 2>>"$LOG_FILE"; then
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

NEW_COUNT_AFTER=$(wc -l < "$ARCHIVE_FILE")
NEW_TRACKS=$((NEW_COUNT_AFTER - NEW_COUNT_BEFORE))

echo "[$(date -Is)] Done. New tracks this run: $NEW_TRACKS" >> "$LOG_FILE"

# Only bother pinging Audiobookshelf if something actually changed.
if [ "$NEW_TRACKS" -gt 0 ] && [ -n "$AUDIOBOOKSHELF_TOKEN" ] && [ -n "$AUDIOBOOKSHELF_LIBRARY_ID" ]; then
  echo "[$(date -Is)] Triggering Audiobookshelf scan..." >> "$LOG_FILE"

  curl -s --connect-timeout 5 --max-time 10 \
    -X POST "$AUDIOBOOKSHELF_URL/api/libraries/$AUDIOBOOKSHELF_LIBRARY_ID/scan" \
    -H "Authorization: Bearer $AUDIOBOOKSHELF_TOKEN" >> "$LOG_FILE" 2>&1

  echo "[$(date -Is)] Scan triggered." >> "$LOG_FILE"
fi
