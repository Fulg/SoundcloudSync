#!/bin/bash
set -euo pipefail

PUID=${PUID:-99}
PGID=${PGID:-100}

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

# Write the crontab under the app user's name — busybox crond runs
# /etc/crontabs/<username> as that user automatically
echo "${CRON_SCHEDULE:-0 */6 * * *} /usr/local/bin/soundcloud-sync.sh" > "/etc/crontabs/$USER_NAME"

# Run immediately on startup so you don't wait for the first cron tick
echo "[startup] Running initial sync..."
su-exec "$USER_NAME" /usr/local/bin/soundcloud-sync.sh || true

# crond stays root (needed to read /etc/crontabs/) but executes jobs as the named user
exec crond -f -l 8
