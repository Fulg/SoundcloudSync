#!/usr/bin/env bash
# Re-tags all chapter files already on disk with ALBUM = episode folder name.
# Run once after deploying the ALBUM fix, before wiping and rescanning ABS.
#
# Usage: bash retag.sh /path/to/music/dir
set -euo pipefail
MUSIC_DIR="${1:?Usage: $0 MUSIC_DIR}"

while IFS= read -r -d '' chapter; do
  dir=$(dirname "$chapter")
  dir_name=$(basename "$dir")
  stem=$(basename "${chapter%.*}")
  ext="${chapter##*.}"
  [[ "$stem" =~ ^([0-9][0-9])\ -\ (.+)$ ]] || continue
  track=$((10#${BASH_REMATCH[1]}))
  title="${BASH_REMATCH[2]}"
  tmp="${chapter}.tmp.${ext}"
  if ffmpeg -y -loglevel error -i "$chapter" -map 0 -c copy \
        -metadata title="$title" -metadata track="$track" -metadata ALBUM="$dir_name" "$tmp" 2>&1; then
    mv "$tmp" "$chapter"
    echo "Fixed: [$dir_name] track=$track title=$title"
  else
    rm -f "$tmp"
    echo "FAILED: $chapter" >&2
  fi
done < <(find "$MUSIC_DIR" -type f \( -name "*.webm" -o -name "*.opus" -o -name "*.m4a" \) -print0)
