#!/usr/bin/env bash

set -Eeuo pipefail

log() {
    printf '[Wolf'\''s Den] %s\n' "$*"
}

fatal() {
    printf '[Wolf'\''s Den] ERROR: %s\n' "$*" >&2
    exit 1
}

is_true() {
    case "${1,,}" in
        true|1|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

bool_number() {
    if is_true "$1"; then
        printf '1'
    else
        printf '0'
    fi
}

escape_config_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

prepare_directories() {
    log "Preparing persistent directories."

    mkdir -p \
        "${SERVER_DIR}" \
        "${CONFIG_DIR}" \
        "${PROFILE_DIR}" \
        "${WORKSHOP_DIR}" \
        "${BACKUP_DIR}"

    chown -R "${PUID}:${PGID}" \
        "${SERVER_DIR}" \
        "${CONFIG_DIR}" \
        "${PROFILE_DIR}" \
        "${WORKSHOP_DIR}" \
        "${BACKUP_DIR}" \
        "${DAYZ_HOME}"
}

update_server() {
    if ! is_true "${UPDATE_SERVER}"; then
        log "Automatic DayZ server updates are disabled."
        return
    fi

    log "Installing or updating the DayZ dedicated server."

    local update_command=(
        steamcmd
        +force_install_dir "${SERVER_DIR}"
    )

    if [[ -n "${STEAM_GUARD_CODE}" ]]; then
        update_command+=(
            +set_steam_guard_code "${STEAM_GUARD_CODE}"
        )
    fi

    update_command+=(
        +login "${STEAM_USER}" "${STEAM_PASSWORD}"
        +app_update "${STEAM_APP_ID}"
    )

    if is_true "${VALIDATE_SERVER}"; then
        update_command+=(validate)
    fi

    update_command+=(+quit)

    gosu "${PUID}:${PGID}" \
        env HOME="${DAYZ_HOME}" USER="${DAYZ_USER}" \
        "${update_command[@]}"
}

normalize_mod_ids() {
    local raw_ids="$1"

    raw_ids="${raw_ids//,/;}"
    raw_ids="${raw_ids// /;}"

    printf '%s' "${raw_ids}" |
        tr ';' '\n' |
        sed '/^[[:space:]]*$/d' |
        awk '!seen[$0]++'
}

download_mod() {
    local mod_id="$1"

    [[ "${mod_id}" =~ ^[0-9]+$ ]] ||
        fatal "Invalid Workshop mod ID: ${mod_id}"

    log "Downloading or updating Workshop mod ${mod_id}."

    local workshop_command=(steamcmd)
    
    if [[ -n "${STEAM_GUARD_CODE}" ]]; then
        workshop_command+=(
            +set_steam_guard_code "${STEAM_GUARD_CODE}"
        )
    fi
    
    workshop_command+=(
        +login "${STEAM_USER}" "${STEAM_PASSWORD}"
        +workshop_download_item "${STEAM_WORKSHOP_APP_ID}" "${mod_id}" validate
        +quit
    )
    
    gosu "${PUID}:${PGID}" \
        env HOME="${DAYZ_HOME}" USER="${DAYZ_USER}" \
        "${workshop_command[@]}"

    local steam_workshop_path="${DAYZ_HOME}/Steam/steamapps/workshop/content/${STEAM_WORKSHOP_APP_ID}/${mod_id}"
    local persistent_mod_path="${WORKSHOP_DIR}/${mod_id}"
    local server_link="${SERVER_DIR}/@${mod_id}"

    if [[ ! -d "${steam_workshop_path}" ]]; then
        fatal "Workshop mod ${mod_id} was not found after downloading."
    fi

    rm -rf "${persistent_mod_path}"
    cp -a "${steam_workshop_path}" "${persistent_mod_path}"
    chown -R "${PUID}:${PGID}" "${persistent_mod_path}"

    ln -sfn "${persistent_mod_path}" "${server_link}"

    mkdir -p "${SERVER_DIR}/keys"
    
    while IFS= read -r key_file; do
        log "Installing mod key $(basename "${key_file}") for Workshop mod ${mod_id}."
        cp -f "${key_file}" "${SERVER_DIR}/keys/"
    done < <(
        find "${persistent_mod_path}" \
            -maxdepth 4 \
            -type f \
            -iname '*.bikey'
    )
    
    chown -R "${PUID}:${PGID}" "${SERVER_DIR}/keys"
}

update_mods() {
    if ! is_true "${UPDATE_MODS}"; then
        log "Automatic Workshop updates are disabled."
        return
    fi

    local all_mod_ids
    all_mod_ids="$(
        {
            normalize_mod_ids "${MOD_IDS}"
            normalize_mod_ids "${SERVER_MOD_IDS}"
        } | awk '!seen[$0]++'
    )"

    if [[ -z "${all_mod_ids}" ]]; then
        log "No Workshop mod IDs are configured."
        return
    fi

    while IFS= read -r mod_id; do
        [[ -n "${mod_id}" ]] && download_mod "${mod_id}"
    done <<< "${all_mod_ids}"

    chown -R "${PUID}:${PGID}" "${SERVER_DIR}/keys"
}

cleanup_stale_mods() {
    local active_mods
    active_mods="$(
        {
            normalize_mod_ids "${MOD_IDS}"
            normalize_mod_ids "${SERVER_MOD_IDS}"
        } | awk '!seen[$0]++'
    )"

    while IFS= read -r symlink; do
        local mod_id
        mod_id="$(basename "${symlink}" | sed 's/@//')"

        if ! printf '%s\n' "${active_mods}" | grep -qx "${mod_id}"; then
            log "Removing stale mod @${mod_id} — not in current mod list."
            rm -f "${symlink}"
            rm -rf "${WORKSHOP_DIR}/${mod_id}"
        fi
    done < <(find "${SERVER_DIR}" -maxdepth 1 -name '@[0-9]*')
}

create_mod_parameter() {
    local raw_ids="$1"
    local parameter_name="$2"
    local mod_list=""

    while IFS= read -r mod_id; do
        [[ -z "${mod_id}" ]] && continue

        if [[ -n "${mod_list}" ]]; then
            mod_list+=";"
        fi

        mod_list+="@${mod_id}"
    done < <(normalize_mod_ids "${raw_ids}")

    if [[ -n "${mod_list}" ]]; then
        printf '%s=%s' "${parameter_name}" "${mod_list}"
    fi
}

create_server_config() {
    local config_path="${CONFIG_DIR}/${SERVER_CONFIG}"

    log "Generating ${config_path}."

    local escaped_name
    local escaped_password
    local escaped_admin_password

    escaped_name="$(escape_config_value "${SERVER_NAME}")"
    escaped_password="$(escape_config_value "${SERVER_PASSWORD}")"
    escaped_admin_password="$(escape_config_value "${ADMIN_PASSWORD}")"

    cat > "${config_path}" <<EOF
hostname = "${escaped_name}";
password = "${escaped_password}";
passwordAdmin = "${escaped_admin_password}";

description = "$(escape_config_value "${SERVER_DESCRIPTION}")";
maxPlayers = ${SERVER_MAX_PLAYERS};

verifySignatures = ${VERIFY_SIGNATURES};
forceSameBuild = $(bool_number "${FORCE_SAME_BUILD}");
enableWhitelist = $(bool_number "${ENABLE_WHITELIST}");

disableVoN = $(is_true "${VOICE_CHAT}" && printf '0' || printf '1');
vonCodecQuality = ${VOICE_QUALITY};

disable3rdPerson = $(is_true "${THIRD_PERSON}" && printf '0' || printf '1');
disableCrosshair = $(is_true "${CROSSHAIR}" && printf '0' || printf '1');

serverTime = "SystemTime";
serverTimePersistent = $(bool_number "${PERSISTENT_TIME}");
serverTimeAcceleration = ${SERVER_TIME_ACCELERATION};
serverNightTimeAcceleration = ${NIGHT_TIME_ACCELERATION};

guaranteedUpdates = 1;
loginQueueConcurrentPlayers = 5;
loginQueueMaxPlayers = 500;

instanceId = 1;
storageAutoFix = 1;

motd[] =
{
    "Welcome to Wolf's Den - survive, build, trade and defend what is yours.",
    "New survivors should establish shelter before entering military territory.",
    "BaseBuildingPlus and Code Lock are available for secure player bases.",
    "AI patrols and hostile survivors may be encountered throughout Chernarus.",
    "Traders offer equipment and supplies, but nothing is truly free.",
    "Raiding is permitted only during the announced weekend raid window.",
    "Exploiting, combat logging and abusive behavior will result in removal.",
    "Vehicles are valuable. Secure them, maintain them and avoid abandoning them.",
    "Server restarts and important announcements will be displayed in advance.",
    "Join our community Discord: DISCORD-LINK-HERE",
    "Trust carefully. Every friendly voice may be hiding desperate intentions.",
    "The wolves are always watching."
};
motdInterval = ${MOTD_INTERVAL};

class Missions
{
    class DayZ
    {
        template = "dayzOffline.chernarusplus";
    };
};
EOF

    chown "${PUID}:${PGID}" "${config_path}"
}

create_backup() {
    if ! is_true "${BACKUP_ON_START}"; then
        log "Startup backups are disabled."
        return
    fi

    local timestamp
    local backup_file

    timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
    backup_file="${BACKUP_DIR}/wolfs-den_${timestamp}.tar.gz"

    log "Creating startup backup."

    tar \
        --ignore-failed-read \
        -czf "${backup_file}" \
        -C /dayz \
        config \
        profiles \
        server/mpmissions 2>/dev/null || true

    chown "${PUID}:${PGID}" "${backup_file}" 2>/dev/null || true

    if [[ "${BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
        find "${BACKUP_DIR}" \
            -type f \
            -name 'wolfs-den_*.tar.gz' \
            -mtime "+${BACKUP_RETENTION_DAYS}" \
            -delete
    fi
}

server_pid=""

stop_server() {
    log "Shutdown requested. Stopping DayZ gracefully."

    if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
        kill -SIGINT "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    fi
}

start_server() {
    local executable="${SERVER_DIR}/DayZServer"

    [[ -x "${executable}" ]] ||
        fatal "DayZServer executable was not found at ${executable}."

    local client_mod_parameter
    local server_mod_parameter

    client_mod_parameter="$(create_mod_parameter "${MOD_IDS}" "-mod")"
    server_mod_parameter="$(create_mod_parameter "${SERVER_MOD_IDS}" "-serverMod")"

    local startup_command=(
        "${executable}"
        "-config=${CONFIG_DIR}/${SERVER_CONFIG}"
        "-profiles=${PROFILE_DIR}"
        "-port=${SERVER_PORT}"
        "-cpuCount=${SERVER_CPU_COUNT}"
        "-doLogs"
        "-adminLog"
        "-netLog"
        "-freezeCheck"
    )

    if [[ -n "${client_mod_parameter}" ]]; then
        startup_command+=("${client_mod_parameter}")
    fi

    if [[ -n "${server_mod_parameter}" ]]; then
        startup_command+=("${server_mod_parameter}")
    fi

    if [[ -n "${ADDITIONAL_STARTUP_ARGS}" ]]; then
        read -r -a additional_arguments <<< "${ADDITIONAL_STARTUP_ARGS}"
        startup_command+=("${additional_arguments[@]}")
    fi

    log "Starting ${SERVER_NAME}."

    cd "${SERVER_DIR}"

    gosu "${PUID}:${PGID}" "${startup_command[@]}" &
    server_pid="$!"

    wait "${server_pid}"
}

main() {
    case "${1:-start}" in
        start)
            prepare_directories
            create_backup
            update_server
            cleanup_stale_mods
            update_mods
            create_server_config

            trap stop_server SIGINT SIGTERM

            start_server
            ;;
        update)
            prepare_directories
            update_server
            update_mods
            ;;
        backup)
            prepare_directories
            create_backup
            ;;
        *)
            exec "$@"
            ;;
    esac
}

main "$@"