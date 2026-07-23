#!/bin/bash
set -euo pipefail

PUID=${PUID:-99}
PGID=${PGID:-100}
UMASK=${UMASK:-022}

# Create the group for PGID if it doesn't already exist
if ! grep -q ":${PGID}:" /etc/group 2>/dev/null; then
    addgroup -g "$PGID" appgroup
fi
GROUP_NAME=$(grep ":${PGID}:" /etc/group | cut -d: -f1 | head -n1)

# Create the user for PUID if it doesn't already exist
if ! grep -q "^[^:]*:[^:]*:${PUID}:" /etc/passwd 2>/dev/null; then
    adduser -D -H -u "$PUID" -G "$GROUP_NAME" appuser
fi
USER_NAME=$(grep "^[^:]*:[^:]*:${PUID}:" /etc/passwd | cut -d: -f1 | head -n1)

echo "[init] Running as $USER_NAME (uid=$PUID gid=$PGID)"

# Fix ownership of the mounted volumes so the app user can write to them
chown -R "$PUID:$PGID" /music /state

# Persist script config to /state/.env so cron-fired runs can read it.
# Busybox crond strips the container environment entirely, so without this
# every cron run would use placeholder defaults instead of configured values.
{
  printf 'export SOUNDCLOUD_URL=%q\n'   "${SOUNDCLOUD_URL:-}"
  printf 'export MUSIC_DIR=%q\n'        "${MUSIC_DIR:-/music}"
  printf 'export STATE_DIR=%q\n'        "${STATE_DIR:-/state}"
  printf 'export NAVIDROME_URL=%q\n'    "${NAVIDROME_URL:-}"
  printf 'export NAVIDROME_USER=%q\n'   "${NAVIDROME_USER:-}"
  printf 'export NAVIDROME_PASS=%q\n'   "${NAVIDROME_PASS:-}"
  printf 'export TITLE_FILTER=%q\n'     "${TITLE_FILTER:-}"
  printf 'export DATE_AFTER=%q\n'       "${DATE_AFTER:-}"
  printf 'export SPLIT_CHAPTERS=%q\n'   "${SPLIT_CHAPTERS:-}"
  printf 'export PLAYLIST_REVERSE=%q\n' "${PLAYLIST_REVERSE:-}"
} > /state/.env
chown "$PUID:$PGID" /state/.env
chmod 600 /state/.env

# Bake the resolved umask value into the cron command — busybox crond does not
# inherit the container environment, so we can't rely on the UMASK variable there
echo "${CRON_SCHEDULE:-0 */6 * * *} sh -c 'umask $UMASK && /usr/local/bin/soundcloud-sync.sh'" > "/etc/crontabs/$USER_NAME"

# Clear any lock file left over from a previous container run. The lock is
# stored on the persistent /state volume, but a restarting container always
# has a fresh process namespace so any existing lock is guaranteed stale.
rm -f /state/sync.lock

# Run immediately on startup so you don't wait for the first cron tick
echo "[startup] Running initial sync..."
umask "$UMASK"
su-exec "$USER_NAME" /usr/local/bin/soundcloud-sync.sh || true

# crond stays root (needed to read /etc/crontabs/) but executes jobs as the named user
exec crond -f -l 8
