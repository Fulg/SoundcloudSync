FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    ffmpeg \
    curl \
    python3 \
    py3-pip \
    su-exec \
    util-linux \
    && pip3 install --break-system-packages yt-dlp curl-cffi mutagen

COPY soundcloud-sync.sh /usr/local/bin/soundcloud-sync.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/soundcloud-sync.sh /entrypoint.sh

VOLUME ["/music", "/state"]

ENV SOUNDCLOUD_URL="https://soundcloud.com/ARTIST_NAME/tracks" \
    MUSIC_DIR="/music" \
    STATE_DIR="/state" \
    AUDIOBOOKSHELF_URL="http://localhost:13378" \
    AUDIOBOOKSHELF_TOKEN="" \
    AUDIOBOOKSHELF_LIBRARY_ID="" \
    CRON_SCHEDULE="0 */6 * * *" \
    TITLE_FILTER="" \
    DATE_AFTER="" \
    SPLIT_CHAPTERS="" \
    PLAYLIST_REVERSE="" \
    PUID=99 \
    PGID=100 \
    UMASK=022

ENTRYPOINT ["/entrypoint.sh"]
