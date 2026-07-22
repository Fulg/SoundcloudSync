#!/bin/bash
set -euo pipefail

# Write cron schedule using the CRON_SCHEDULE env var (default: every 6 hours)
echo "${CRON_SCHEDULE:-0 */6 * * *} /usr/local/bin/soundcloud-sync.sh" > /etc/crontabs/root

# Run immediately on container start so you don't wait for the first cron tick
echo "[startup] Running initial sync..."
/usr/local/bin/soundcloud-sync.sh || true

# Hand off to crond in foreground so the container stays alive
exec crond -f -l 8
