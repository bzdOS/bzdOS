#!/bin/sh
set -eu

## MAKE-TARGETS ##
# zfs-profile-create: USER=$(USER) $(SCRIPTS)/zfs-crypto.sh create-profile $(USER)
# zfs-profile-load:   USER=$(USER) $(SCRIPTS)/zfs-crypto.sh load-key $(USER)
# zfs-profile-unload: USER=$(USER) $(SCRIPTS)/zfs-crypto.sh unload-key $(USER)
# zfs-profile-status: $(SCRIPTS)/zfs-crypto.sh status
# zfs-wipe-keys:      $(SCRIPTS)/zfs-crypto.sh wipe-keys
## END-MAKE-TARGETS ##

. "$(dirname "$0")/_agent.sh"

# Константы
ZPOOL="zroot"
PROFILE_BASE="${ZPOOL}/bsdos/profiles"
PROFILE_MOUNT_BASE="/opt/proto/profiles"

# Печать сообщений
log_info()  { printf '[INFO] %s\n' "$1"; }
log_err()   { printf '[ERR]  %s\n' "$1" >&2; }
log_ok()    { printf '[OK]   %s\n' "$1"; }

# ────────────────────────────────────────────────────────────────────
# create-profile USER
# Создать зашифрованный ZFS датасет для пользователя с интерактивным паролем
# ────────────────────────────────────────────────────────────────────
cmd_create_profile() {
    local user="${1:?usage: create-profile USER}"

    log_info "Creating encrypted ZFS profile for user: $user"

    # Проверить что профиль не существует
    if agent_exec "zfs list $PROFILE_BASE/$user 2>/dev/null" >/dev/null 2>&1; then
        log_err "Profile already exists: $PROFILE_BASE/$user"
        return 1
    fi

    # Убедиться что parent dataset существует
    if ! agent_exec "zfs list $PROFILE_BASE 2>/dev/null" >/dev/null 2>&1; then
        log_info "Creating parent dataset: $PROFILE_BASE"
        agent_exec "zfs create $PROFILE_BASE"
    fi

    # Создать зашифрованный датасет с интерактивным вводом пароля
    # Таймаут 60 секунд для ввода пароля пользователем
    log_info "Creating encrypted dataset (you will be prompted for passphrase)..."
    AGENT_EXEC_TIMEOUT=60 agent_exec \
        "zfs create -o encryption=aes-256-gcm \
                    -o keyformat=passphrase \
                    -o keylocation=prompt \
                    -o mountpoint=$PROFILE_MOUNT_BASE/$user \
                    $PROFILE_BASE/$user"

    if [ $? -eq 0 ]; then
        log_ok "Profile created: $PROFILE_BASE/$user"
        log_ok "Mounted at: $PROFILE_MOUNT_BASE/$user"
    else
        log_err "Failed to create profile"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────────
# load-key USER
# Загрузить ключ и смонтировать датасет (разблокировка)
# ────────────────────────────────────────────────────────────────────
cmd_load_key() {
    local user="${1:?usage: load-key USER}"

    log_info "Loading encryption key for profile: $user"

    # Проверить что датасет существует
    if ! agent_exec "zfs list $PROFILE_BASE/$user 2>/dev/null" >/dev/null 2>&1; then
        log_err "Profile does not exist: $PROFILE_BASE/$user"
        return 1
    fi

    # Загрузить ключ (интерактивно с паролем)
    log_info "Enter passphrase when prompted..."
    AGENT_EXEC_TIMEOUT=60 agent_exec \
        "zfs load-key $PROFILE_BASE/$user && \
         zfs mount $PROFILE_BASE/$user"

    if [ $? -eq 0 ]; then
        log_ok "Key loaded and dataset mounted: $PROFILE_BASE/$user"
    else
        log_err "Failed to load key"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────────
# unload-key USER
# Выгрузить ключ и размонтировать датасет (блокировка)
# ────────────────────────────────────────────────────────────────────
cmd_unload_key() {
    local user="${1:?usage: unload-key USER}"

    log_info "Unloading encryption key for profile: $user"

    # Проверить что датасет существует
    if ! agent_exec "zfs list $PROFILE_BASE/$user 2>/dev/null" >/dev/null 2>&1; then
        log_err "Profile does not exist: $PROFILE_BASE/$user"
        return 1
    fi

    # Размонтировать и выгрузить ключ
    agent_exec \
        "zfs umount $PROFILE_BASE/$user 2>/dev/null || true; \
         zfs unload-key $PROFILE_BASE/$user"

    if [ $? -eq 0 ]; then
        log_ok "Key unloaded and dataset unmounted: $PROFILE_BASE/$user"
    else
        log_err "Failed to unload key"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────────
# status
# Показать статус всех profile датасетов
# ────────────────────────────────────────────────────────────────────
cmd_status() {
    log_info "ZFS Crypto Profiles Status"
    log_info "─────────────────────────────────────────────────────────────"

    # Показать header
    printf '%-40s %-12s %-12s %-10s\n' "NAME" "ENCRYPTION" "KEYSTATUS" "MOUNTED"
    printf '%-40s %-12s %-12s %-10s\n' "────────────────────────────────────" "──────────" "──────────" "────────"

    # Получить данные (если пул/датасет существует)
    agent_exec "zfs list -H -o name,encryption,keystatus,mounted $PROFILE_BASE 2>/dev/null || echo '(no profiles)'" \
        | while read -r line; do
            if [ -n "$line" ] && [ "$line" != "(no profiles)" ]; then
                printf '%s\n' "$line" | awk '{
                    printf "%-40s %-12s %-12s %-10s\n", $1, $2, $3, $4
                }'
            fi
        done

    if agent_exec "zfs list -H $PROFILE_BASE 2>/dev/null" >/dev/null 2>&1; then
        log_ok "Status complete"
    else
        log_info "No profiles found (parent dataset may not exist yet)"
    fi
}

# ────────────────────────────────────────────────────────────────────
# destroy USER
# Удалить профиль с подтверждением
# ────────────────────────────────────────────────────────────────────
cmd_destroy() {
    local user="${1:?usage: destroy USER}"

    log_info "Destroying profile: $user"

    # Проверить что датасет существует
    if ! agent_exec "zfs list $PROFILE_BASE/$user 2>/dev/null" >/dev/null 2>&1; then
        log_err "Profile does not exist: $PROFILE_BASE/$user"
        return 1
    fi

    # Спросить подтверждение
    printf "Are you sure you want to destroy profile '%s'? [y/N] " "$user" >&2
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Cancelled"
        return 0
    fi

    # Попробовать размонтировать если смонтирован
    agent_exec "zfs umount $PROFILE_BASE/$user 2>/dev/null || true" >/dev/null 2>&1 || true

    # Удалить датасет рекурсивно
    agent_exec "zfs destroy -r $PROFILE_BASE/$user"

    if [ $? -eq 0 ]; then
        log_ok "Profile destroyed: $PROFILE_BASE/$user"
    else
        log_err "Failed to destroy profile"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────────
# wipe-keys
# Аварийная команда: выгрузить ключи для ВСЕх profiles
# (RAM crypto-sleep при блокировке)
# ────────────────────────────────────────────────────────────────────
cmd_wipe_keys() {
    log_info "EMERGENCY: Wiping all encryption keys (fire and forget)"

    # Использовать agent_exec_bg для асинхронного выполнения
    agent_exec_bg "zfs list -H -o name $PROFILE_BASE 2>/dev/null | \
        xargs -r -I {} sh -c 'zfs umount {} 2>/dev/null || true; zfs unload-key {} 2>/dev/null || true'"

    if [ $? -eq 0 ]; then
        log_ok "Wipe-keys command sent (background)"
    else
        log_err "Failed to send wipe-keys command"
        return 1
    fi
}

# ────────────────────────────────────────────────────────────────────
# main
# ────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"

    case "$cmd" in
        create-profile)
            cmd_create_profile "$2"
            ;;
        load-key)
            cmd_load_key "$2"
            ;;
        unload-key)
            cmd_unload_key "$2"
            ;;
        status)
            cmd_status
            ;;
        destroy)
            cmd_destroy "$2"
            ;;
        wipe-keys)
            cmd_wipe_keys
            ;;
        *)
            cat >&2 <<'EOF'
ZFS Crypto Profiles Management

Usage:
  zfs-crypto.sh create-profile USER   — create encrypted ZFS dataset for user
  zfs-crypto.sh load-key USER         — unlock and mount user profile
  zfs-crypto.sh unload-key USER       — lock and unmount user profile
  zfs-crypto.sh status                — show all profile statuses
  zfs-crypto.sh destroy USER          — delete profile (with confirmation)
  zfs-crypto.sh wipe-keys             — emergency: unload all keys (bg)

Environment:
  AGENT_EXEC_TIMEOUT=N  — timeout for interactive commands (default 30s)

Pool & Dataset Base:
  Pool: zroot
  Datasets: zroot/bsdos/profiles/USER
  Mounts: /opt/proto/profiles/USER
EOF
            return 1
            ;;
    esac
}

main "$@"
