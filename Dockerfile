FROM steamcmd/steamcmd:ubuntu-22

LABEL org.opencontainers.image.title="Wolf's Den DayZ Server"
LABEL org.opencontainers.image.description="Modded DayZ Linux server with Steam Workshop and Unraid support"
LABEL org.opencontainers.image.source="https://github.com/BrokkrForgemaster/dayz-server"

ENV DEBIAN_FRONTEND=noninteractive

# Unraid ownership defaults
ENV PUID=99 \
    PGID=100

# DayZ filesystem locations
ENV DAYZ_USER=dayz \
    DAYZ_HOME=/home/dayz \
    HOME=/home/dayz \
    SERVER_DIR=/dayz/server \
    CONFIG_DIR=/dayz/config \
    PROFILE_DIR=/dayz/profiles \
    WORKSHOP_DIR=/dayz/workshop \
    BACKUP_DIR=/dayz/backups

# Steam applications
ENV STEAM_APP_ID=223350 \
    STEAM_WORKSHOP_APP_ID=221100 \
    STEAM_USER=anonymous \
    STEAM_PASSWORD="" \
    STEAM_GUARD_CODE=""

# Server identity
ENV SERVER_NAME="Wolf's Den | BBP | AI | Traders | Weekend Raids" \
    SERVER_DESCRIPTION="Survive, build, trade and defend what is yours." \
    SERVER_PASSWORD="" \
    ADMIN_PASSWORD="" \
    SERVER_CONFIG=serverDZ.cfg \
    SERVER_PORT=2302 \
    SERVER_MAX_PLAYERS=40 \
    SERVER_CPU_COUNT=4

# Native DayZ server settings
ENV MOTD_INTERVAL=300 \
    ENABLE_WHITELIST=false \
    VERIFY_SIGNATURES=2 \
    FORCE_SAME_BUILD=true \
    THIRD_PERSON=true \
    CROSSHAIR=false \
    VOICE_CHAT=true \
    VOICE_QUALITY=20 \
    PERSISTENT_TIME=true \
    SERVER_TIME_ACCELERATION=6 \
    NIGHT_TIME_ACCELERATION=4

# Update and backup behavior
ENV UPDATE_SERVER=true \
    UPDATE_MODS=true \
    VALIDATE_SERVER=false \
    BACKUP_ON_START=true \
    BACKUP_RETENTION_DAYS=14

# Workshop mods — load order: frameworks first, then expansion, then content mods
ENV MOD_IDS="1559212036;2545327648;2291785308;2116157322;2291785437;2792982069;2792984177;1623711988;2602208478;2303483532;1565871491;2170927235;1870524790;3787588788;3790029316" \
    SERVER_MOD_IDS="1828439124" \
    ADDITIONAL_STARTUP_ARGS=""

# Container timezone
ENV TZ=America/New_York

USER root

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        findutils \
        gosu \
        jq \
        lib32gcc-s1 \
        lib32stdc++6 \
        libcurl4 \
        libstdc++6 \
        procps \
        tar \
        tzdata \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# Ubuntu supplies the Unraid-compatible users group with GID 100.
RUN useradd \
        --uid "${PUID}" \
        --gid "${PGID}" \
        --home-dir "${DAYZ_HOME}" \
        --create-home \
        --shell /bin/bash \
        "${DAYZ_USER}" \
    && mkdir -p \
        "${DAYZ_HOME}/.steam" \
        "${SERVER_DIR}" \
        "${CONFIG_DIR}" \
        "${PROFILE_DIR}" \
        "${WORKSHOP_DIR}" \
        "${BACKUP_DIR}" \
    && chown -R "${PUID}:${PGID}" \
        /dayz \
        "${DAYZ_HOME}"

COPY --chmod=755 entrypoint.sh /usr/local/bin/dayz-entrypoint

WORKDIR ${SERVER_DIR}

VOLUME ["/dayz/server", "/dayz/config", "/dayz/profiles", "/dayz/workshop", "/dayz/backups"]

# DayZ gameplay and Steam query ports
EXPOSE 2302/udp
EXPOSE 2303/udp
EXPOSE 2304/udp
EXPOSE 2305/udp
EXPOSE 2306/udp
EXPOSE 27016/udp

STOPSIGNAL SIGINT

ENTRYPOINT ["/usr/local/bin/dayz-entrypoint"]
CMD ["start"]