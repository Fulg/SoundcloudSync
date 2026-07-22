FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    ffmpeg \
    curl \
    jq \
    python3 \
    py3-pip \
    su-exec \
    && pip3 install --break-system-packages yt-dlp

COPY soundcloud-sync.sh /usr/local/bin/soundcloud-sync.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/soundcloud-sync.sh /entrypoint.sh

VOLUME ["/music", "/state"]

ENV SOUNDCLOUD_URL="https://soundcloud.com/ARTIST_NAME/tracks" \
    MUSIC_DIR="/music" \
    STATE_DIR="/state" \
    NAVIDROME_URL="http://localhost:4533" \
    NAVIDROME_USER="admin" \
    NAVIDROME_PASS="changeme" \
    CRON_SCHEDULE="0 */6 * * *" \
    PUID=99 \
    PGID=100 \
    UMASK=022

ENTRYPOINT ["/entrypoint.sh"]
