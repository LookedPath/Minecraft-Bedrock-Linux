#!/bin/bash
# Shared configuration loading and Linux process checks.

load_config() {
    if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
        printf '%s\n' "Missing local config.sh. Run: bash $SCRIPT_DIR/setup.sh --init-config, then edit config.sh." >&2
        return 1
    fi
    source "$SCRIPT_DIR/config.sh"
}

create_local_config() {
    local config="$SCRIPT_DIR/config.sh"
    if [[ -e "$config" || -L "$config" ]]; then
        printf '%s\n' "Existing config.sh preserved."
        return 0
    fi
    [[ -f "$SCRIPT_DIR/config.sh.example" ]] || {
        printf '%s\n' "Missing config.sh.example; deploy all release files." >&2; return 1;
    }
    # noclobber prevents overwriting a file created concurrently, including symlinks.
    (umask 077; set -o noclobber; cat -- "$SCRIPT_DIR/config.sh.example" > "$config") || return 1
    printf '%s\n' "Created config.sh from config.sh.example. Review your settings before setup."
}

validate_config() {
    local path canonical other entry
    [[ "$SERVER_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$SERVER_USER" != root ]] || return 1
    [[ "$SERVER_EXECUTABLE" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$SCREEN_SESSION_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || return 1
    [[ "${MAX_EXTRACTED_BYTES:-4294967296}" =~ ^[1-9][0-9]*$ ]] || return 1
    for path in "$SERVER_DIR" "$BACKUP_DIR" "$LOG_DIR"; do
        [[ "$path" == /*/* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
        canonical=$(realpath -m -- "$path") || return 1
        [[ "$canonical" == "$path" ]] || return 1
        case "$path" in
            /bin/*|/sbin/*|/lib/*|/lib64/*|/boot/*|/dev/*|/proc/*|/sys/*|/run/*|/etc/*|/usr/*|/var/log|/var/lib|/var/backups|/home/"$SERVER_USER") return 1 ;;
        esac
    done
    for other in "$BACKUP_DIR" "$LOG_DIR"; do
        [[ "$other" != "$SERVER_DIR" && "$other" != "$SERVER_DIR/"* && "$SERVER_DIR" != "$other/"* ]] || return 1
    done
    [[ "$LOG_FILE" == "$LOG_DIR/"* && ! -L "$LOG_FILE" && "$(realpath -m -- "$LOG_FILE")" == "$LOG_FILE" ]] || return 1
    for entry in "${PRESERVE_FILES[@]}" "${WORLD_DIRS[@]}"; do
        [[ -n "$entry" && "$entry" != . && "$entry" != .. && "$entry" != */* && "$entry" != "$SERVER_EXECUTABLE" && "$entry" != *$'\n'* && "$entry" != *$'\r'* ]] || return 1
    done
}

has_screen_session() {
    local output
    output=$(sudo -u "$SERVER_USER" screen -list 2>/dev/null) || return 1
    # Match the entire session name, rather than a substring or regular expression.
    awk -v name="$SCREEN_SESSION_NAME" '$1 ~ /^[0-9]+\./ {s=$1; sub(/^[0-9]+\./,"",s); if(s==name) found=1} END {exit !found}' <<< "$output"
}

server_pids() {
    local proc pid owner executable cwd uid
    uid=$(id -u "$SERVER_USER") || return 1
    for proc in /proc/[0-9]*; do
        pid=${proc##*/}
        owner=$(stat -c %u "$proc" 2>/dev/null) || continue
        [[ "$owner" == "$uid" ]] || continue
        executable=$(readlink "$proc/exe" 2>/dev/null) || continue
        cwd=$(readlink "$proc/cwd" 2>/dev/null) || continue
        if [[ "$executable" == "$SERVER_DIR/$SERVER_EXECUTABLE" && "$cwd" == "$SERVER_DIR" ]]; then
            printf '%s\n' "$pid"
        fi
    done
}

has_server_process() {
    local pids
    pids=$(server_pids) || return 1
    [[ -n "$pids" ]]
}

# Recheck identity immediately before signaling; never match arbitrary command lines.
signal_server() {
    local signal="$1" pid
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        if server_pids | grep -Fx -- "$pid" >/dev/null; then
            kill -s "$signal" -- "$pid" || return 1
        fi
    done < <(server_pids)
}

# Serialize mutations across updater/start/stop. Updater children inherit fd 9.
acquire_management_lock() {
    local lock_dir=/run/lock/minecraft-bedrock fd_path
    if [[ ! -e "$lock_dir" ]]; then
        mkdir -m 700 -- "$lock_dir" || return 1
    fi
    [[ -d "$lock_dir" && ! -L "$lock_dir" && "$(stat -c %u "$lock_dir")" == 0 && "$(stat -c %a "$lock_dir")" == 700 ]] || {
        printf '%s\n' "Management lock directory must be owned by root with mode 700" >&2; return 1;
    }
    [[ ! -L "$lock_dir/update.lock" ]] || return 1
    fd_path=$(readlink /proc/$$/fd/9 2>/dev/null) || fd_path=""
    if [[ "$fd_path" != "$lock_dir/update.lock" ]]; then
        exec 9>"$lock_dir/update.lock"
    fi
    flock -n 9 || { printf '%s\n' "Another server management operation is running" >&2; return 1; }
}
