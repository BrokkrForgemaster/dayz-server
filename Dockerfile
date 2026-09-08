FROM steamcmd/steamcmd:ubuntu-22

LABEL org.opencontainers.image.title="Wolf's Den" \
      org.opencontainers.image.description="Modded DayZ Linux server with persistent Unraid storage"

USER root
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
        bash ca-certificates curl findutils gosu jq lib32gcc-s1 lib32stdc++6 \
        libcurl4 libstdc++6 procps tar gzip tzdata unzip util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN getent group 100 >/dev/null || groupadd --gid 100 users
RUN useradd --uid 99 --gid 100 --home-dir /home/dayz --create-home --shell /bin/bash dayz \
    && mkdir -p /home/dayz/.steam /dayz/server /dayz/config /dayz/profiles /dayz/workshop /dayz/backups \
    && chown -R 99:100 /dayz /home/dayz

ENV TZ=America/New_York
# Runtime defaults (including mod IDs) are defined only in entrypoint.sh.
COPY --chmod=755 entrypoint.sh /usr/local/bin/dayz-entrypoint
# Handle CRLF if edited on Windows; fail image build on shell syntax errors.
RUN sed -i 's/\r$//' /usr/local/bin/dayz-entrypoint \
    && bash -n /usr/local/bin/dayz-entrypoint
WORKDIR /dayz/server
EXPOSE 2302/udp 2303/udp 2304/udp 2305/udp 2306/udp 27016/udp
STOPSIGNAL SIGINT
ENTRYPOINT ["/usr/local/bin/dayz-entrypoint"]
CMD ["start"]
