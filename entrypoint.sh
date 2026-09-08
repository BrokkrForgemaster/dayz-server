#!/usr/bin/env bash

set -Eeuo pipefail
umask 027
trap 'printf "Startup or maintenance failed at line %s; inspect the preceding error.\n" "$LINENO" >&2' ERR

# Runtime defaults live here, not in competing Dockerfile/Compose ENV blocks.
: "${PUID:=99}" "${PGID:=100}" "${DAYZ_USER:=dayz}" "${DAYZ_HOME:=/home/dayz}"
: "${SERVER_DIR:=/dayz/server}" "${CONFIG_DIR:=/dayz/config}"
: "${PROFILE_DIR:=/dayz/profiles}" "${WORKSHOP_DIR:=/dayz/workshop}" "${BACKUP_DIR:=/dayz/backups}"
: "${STEAM_APP_ID:=223350}" "${STEAM_WORKSHOP_APP_ID:=221100}" "${STEAM_USER:=anonymous}"
: "${STEAM_PASSWORD:=}" "${STEAM_GUARD_CODE:=}" "${ADMIN_PASSWORD:=}" "${SERVER_PASSWORD:=}"
if [[ -z "${SERVER_NAME:-}" ]]; then SERVER_NAME="Wolf's Den"; fi
: "${SERVER_DESCRIPTION:=Survive, build, and defend what is yours.}"
: "${SERVER_CONFIG:=serverDZ.cfg}" "${SERVER_PORT:=2302}" "${SERVER_MAX_PLAYERS:=40}" "${SERVER_CPU_COUNT:=4}"
: "${MOTD_INTERVAL:=300}" "${ENABLE_WHITELIST:=false}" "${VERIFY_SIGNATURES:=2}" "${FORCE_SAME_BUILD:=true}"
: "${THIRD_PERSON:=true}" "${CROSSHAIR:=false}" "${VOICE_CHAT:=true}" "${VOICE_QUALITY:=20}"
: "${PERSISTENT_TIME:=true}" "${SERVER_TIME_ACCELERATION:=6}" "${NIGHT_TIME_ACCELERATION:=4}"
: "${UPDATE_SERVER:=false}" "${UPDATE_MODS:=false}" "${VALIDATE_SERVER:=false}"
: "${BACKUP_ON_START:=true}" "${BACKUP_RETENTION_DAYS:=14}" "${CONFIG_MODE:=preserve}"
: "${FIX_OWNERSHIP:=false}" "${NETWORK_LOGGING:=false}" "${ALLOW_EMPTY_MODS:=false}"
: "${ADDITIONAL_STARTUP_ARGS:=}" "${SERVER_MOD_IDS:=}"
# An explicitly empty list is rejected unless ALLOW_EMPTY_MODS=true.
MOD_IDS="${MOD_IDS-1559212036;2545327648;3690289718;2291785308;2116157322;2291785437;2792982069;2792984177;1565871491;1623711988;2602208478;2303483532;1932611410;2170927235;1870524790;1828439124}"
export DAYZ_USER DAYZ_HOME SERVER_DIR CONFIG_DIR PROFILE_DIR WORKSHOP_DIR BACKUP_DIR


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
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

prepare_directories() {
    mkdir -p "$PROFILE_DIR"
    exec 9>"$PROFILE_DIR/.dayz-start.lock"
    flock -n 9 || fatal "Another reviewed DayZ instance is using this profiles directory."
    mkdir -p "$SERVER_DIR" "$CONFIG_DIR" "$PROFILE_DIR" "$WORKSHOP_DIR" "$BACKUP_DIR" "$DAYZ_HOME"
    chown "$PUID:$PGID" "$SERVER_DIR" "$CONFIG_DIR" "$PROFILE_DIR" "$WORKSHOP_DIR" "$BACKUP_DIR" "$DAYZ_HOME"
    if is_true "$FIX_OWNERSHIP"; then
        log "Repairing ownership recursively (one-time maintenance option)."
        chown -R "$PUID:$PGID" "$SERVER_DIR" "$CONFIG_DIR" "$PROFILE_DIR" "$WORKSHOP_DIR" "$BACKUP_DIR" "$DAYZ_HOME"
    fi
    for path in "$SERVER_DIR" "$CONFIG_DIR" "$PROFILE_DIR" "$WORKSHOP_DIR" "$BACKUP_DIR"; do
        gosu "$PUID:$PGID" test -w "$path" || fatal "Not writable: $path. Run once with FIX_OWNERSHIP=true."
    done
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

    update_command+=(+login "$STEAM_USER")
    if [[ "$STEAM_USER" != anonymous ]]; then
        update_command+=("$STEAM_PASSWORD")
    fi
    update_command+=(+app_update "$STEAM_APP_ID")

    if is_true "${VALIDATE_SERVER}"; then
        update_command+=(validate)
    fi

    update_command+=(+quit)

    gosu "${PUID}:${PGID}" \
        env HOME="${DAYZ_HOME}" USER="${DAYZ_USER}" \
        "${update_command[@]}"
}

normalize_mod_ids() {
    printf '%s\n' "$1" | tr ',;[:space:]' '\n' | sed '/^$/d' | awk '!seen[$0]++'
}

download_mod() {
    local mod_id="$1"
    log "Downloading Workshop mod $mod_id."
    # SteamCMD runs from DAYZ_HOME; support both common SteamCMD download roots.
    local cmd=(steamcmd)
    [[ -z "$STEAM_GUARD_CODE" ]] || cmd+=(+set_steam_guard_code "$STEAM_GUARD_CODE")
    cmd+=(+login "$STEAM_USER")
    [[ "$STEAM_USER" == anonymous ]] || cmd+=("$STEAM_PASSWORD")
    cmd+=(+workshop_download_item "$STEAM_WORKSHOP_APP_ID" "$mod_id" validate +quit)
    (cd "$DAYZ_HOME"; gosu "$PUID:$PGID" env HOME="$DAYZ_HOME" USER="$DAYZ_USER" "${cmd[@]}")

    local source="" candidate stage previous target="$WORKSHOP_DIR/$mod_id"
    for candidate in \
        "$DAYZ_HOME/Steam/steamapps/workshop/content/$STEAM_WORKSHOP_APP_ID/$mod_id" \
        "$DAYZ_HOME/steamapps/workshop/content/$STEAM_WORKSHOP_APP_ID/$mod_id" \
        "/root/.local/share/Steam/steamapps/workshop/content/$STEAM_WORKSHOP_APP_ID/$mod_id" \
        "/root/Steam/steamapps/workshop/content/$STEAM_WORKSHOP_APP_ID/$mod_id"; do
        if [[ -d "$candidate" ]]; then source="$candidate"; break; fi
    done
    [[ -n "$source" ]] || fatal "Cannot locate downloaded mod $mod_id. Check SteamCMD output and download directory. Existing copy retained."
    [[ -n "$(find "$source" -type f -iname '*.pbo' -print -quit)" ]] || fatal "Downloaded mod $mod_id has no PBOs; existing copy retained."
    stage=$(mktemp -d "$WORKSHOP_DIR/.stage-$mod_id.XXXXXX")
    cp -a "$source/." "$stage/"
    chown -R "$PUID:$PGID" "$stage"
    previous="$WORKSHOP_DIR/.previous-$mod_id-$(date +%s)-$$"
    if [[ -e "$target" || -L "$target" ]]; then mv "$target" "$previous"; fi
    if ! mv "$stage" "$target"; then
        [[ ! -e "$previous" ]] || mv "$previous" "$target"
        fatal "Could not activate $mod_id."
    fi
    # Keep previous copy for rollback; never delete user Workshop content automatically.
    [[ ! -e "$previous" ]] || log "Previous mod copy retained at $previous."
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

    # Key installation is handled by prepare_mods, including when updates are disabled.
}

prepare_mods() {
    local id target link key
    mkdir -p "$SERVER_DIR/keys"
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        target="$WORKSHOP_DIR/$id"
        link="$SERVER_DIR/@$id"
        if [[ -d "$target" ]]; then
            if [[ -e "$link" && ! -L "$link" ]]; then
                fatal "$link is a real directory. Reconcile it with $target manually; it will not be overwritten."
            fi
            ln -sfnT "$target" "$link"
        elif [[ -d "$link" && ! -L "$link" ]]; then
            target="$link"
        else
            fatal "Missing mod $id. Download it or enable UPDATE_MODS=true."
        fi
        [[ -n "$(find "$target" -type f -iname '*.pbo' -print -quit)" ]] || fatal "No PBO files in $target."
        while IFS= read -r -d '' key; do
            cp -f "$key" "$SERVER_DIR/keys/"
        done < <(find "$target" -maxdepth 4 -type f -iname '*.bikey' -print0)
    done < <(printf '%s\n%s\n' "$MOD_IDS" "$SERVER_MOD_IDS" | tr ';' '\n' | sed '/^$/d' | awk '!seen[$0]++')
    chown -R "$PUID:$PGID" "$SERVER_DIR/keys"
    # Inactive directories/symlinks and old keys are retained. Only listed mods launch.
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

    if [[ -f "$config_path" && "$CONFIG_MODE" == preserve ]]; then
        log "Preserving existing $config_path; gameplay ENV changes will not overwrite it."
        gosu "$PUID:$PGID" test -r "$config_path" || fatal "Config is unreadable by DayZ."
        return
    fi
    [[ -n "$ADMIN_PASSWORD" && "$ADMIN_PASSWORD" != change-this-admin-password && "$ADMIN_PASSWORD" != REPLACE_WITH_A_NEW_UNIQUE_PASSWORD ]] || fatal "Set ADMIN_PASSWORD before generating config."
    log "Generating ${config_path}."
    local destination="$config_path"
    config_path=$(mktemp "$CONFIG_DIR/.server-config.XXXXXX")

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
    "AI patrols and hostile survivors may be encountered throughout Chernarus.",
    "Raiding is permitted only during the announced weekend raid window.",
    "Exploiting, combat logging and abusive behavior will result in removal.",
    "Vehicles are valuable. Secure them, maintain them and avoid abandoning them.",
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
    chmod 640 "$config_path"
    mv -f "$config_path" "$destination"
}

create_backup() {
    if ! is_true "$BACKUP_ON_START"; then log "Startup backups disabled."; return; fi
    local destination="$BACKUP_DIR/wolfs-den_$(date '+%Y-%m-%d_%H-%M-%S')_$$.tar.gz"
    local temporary="${destination%.gz}.partial"
    # Each tar invocation has its own transform; preserve symlinks as symlinks.
    tar -cf "$temporary" --transform='flags=r;s,^\./,config/,;s,^\.$,config/,' -C "$CONFIG_DIR" .
    tar -rf "$temporary" --transform='flags=r;s,^\./,profiles/,;s,^\.$,profiles/,' -C "$PROFILE_DIR" .
    if [[ -d "$SERVER_DIR/mpmissions" ]]; then
        tar -rf "$temporary" --transform='flags=r;s,^,server/,' -C "$SERVER_DIR" mpmissions
    fi
    gzip "$temporary"
    gzip -t "$temporary.gz"
    mv "$temporary.gz" "$destination"
    chown "$PUID:$PGID" "$destination"
    log "Backup complete: $destination"
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'wolfs-den_*.tar.gz' -mtime "+$BACKUP_RETENTION_DAYS" -delete
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
        "-freezeCheck"
    )

    if is_true "$NETWORK_LOGGING"; then startup_command+=("-netLog"); fi

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

    exec gosu "$PUID:$PGID" "${startup_command[@]}"

}


validate_settings() {
    local field value id
    for field in PUID PGID STEAM_APP_ID STEAM_WORKSHOP_APP_ID SERVER_PORT SERVER_MAX_PLAYERS SERVER_CPU_COUNT MOTD_INTERVAL VOICE_QUALITY VERIFY_SIGNATURES BACKUP_RETENTION_DAYS; do
        value="${!field}"
        [[ "$value" =~ ^[0-9]+$ ]] || fatal "$field must be an unsigned integer."
    done
    (( SERVER_PORT >= 1 && SERVER_PORT <= 65535 && SERVER_MAX_PLAYERS >= 1 && SERVER_CPU_COUNT >= 1 )) || fatal "Invalid port/player/CPU value."
    for field in SERVER_TIME_ACCELERATION NIGHT_TIME_ACCELERATION; do
        [[ "${!field}" =~ ^[0-9]+([.][0-9]+)?$ ]] || fatal "$field must be numeric."
    done
    for field in UPDATE_SERVER UPDATE_MODS VALIDATE_SERVER BACKUP_ON_START FIX_OWNERSHIP NETWORK_LOGGING ALLOW_EMPTY_MODS ENABLE_WHITELIST FORCE_SAME_BUILD THIRD_PERSON CROSSHAIR VOICE_CHAT PERSISTENT_TIME; do
        value="${!field}"
        case "${value,,}" in true|false|1|0|yes|no|on|off) ;; *) fatal "$field must be a boolean.";; esac
    done
    [[ "$SERVER_CONFIG" =~ ^[A-Za-z0-9_.-]+$ && "$SERVER_CONFIG" != . && "$SERVER_CONFIG" != .. ]] || fatal "SERVER_CONFIG must be a filename."
    [[ "$CONFIG_MODE" == preserve || "$CONFIG_MODE" == generate ]] || fatal "CONFIG_MODE must be preserve or generate."
    for field in SERVER_NAME SERVER_DESCRIPTION SERVER_PASSWORD ADMIN_PASSWORD; do
        [[ "${!field}" != *$'\n'* && "${!field}" != *$'\r'* ]] || fatal "$field cannot contain newlines."
    done
    MOD_IDS=$(normalize_mod_ids "$MOD_IDS" | paste -sd ';' -)
    SERVER_MOD_IDS=$(normalize_mod_ids "$SERVER_MOD_IDS" | paste -sd ';' -)
    [[ -n "$MOD_IDS$SERVER_MOD_IDS" ]] || is_true "$ALLOW_EMPTY_MODS" || fatal "Empty mod lists rejected; set ALLOW_EMPTY_MODS=true for intentional vanilla."
    while IFS= read -r id; do
        [[ -z "$id" || "$id" =~ ^[0-9]+$ ]] || fatal "Invalid Workshop ID: $id"
    done < <(printf '%s\n%s\n' "$MOD_IDS" "$SERVER_MOD_IDS" | tr ';' '\n')
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        [[ ";$MOD_IDS;" != *";$id;"* ]] || fatal "Mod $id occurs in both MOD_IDS and SERVER_MOD_IDS."
    done < <(printf '%s' "$SERVER_MOD_IDS" | tr ';' '\n'; printf '\n')
}

main() {
    case "${1:-start}" in
        start)
            validate_settings
            prepare_directories
            create_backup
            update_server
            update_mods
            prepare_mods
            create_server_config
            start_server
            ;;
        update)
            validate_settings
            prepare_directories
            BACKUP_ON_START=true create_backup
            UPDATE_SERVER=true update_server
            UPDATE_MODS=true update_mods
            prepare_mods
            ;;
        backup)
            validate_settings
            prepare_directories
            BACKUP_ON_START=true create_backup
            ;;
        *) exec "$@" ;;
    esac
}

main "$@"
