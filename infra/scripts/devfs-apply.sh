#!/bin/sh
## MAKE-TARGETS ##
# devfs-setup:        $(SCRIPTS)/devfs-apply.sh setup
# devfs-apply:        JAIL=$(JAIL) RULESET=$(RULESET) $(SCRIPTS)/devfs-apply.sh apply $(JAIL) $(RULESET)
# devfs-status:       $(SCRIPTS)/devfs-apply.sh status
## END-MAKE-TARGETS ##

set -eu

. "$(dirname "$0")/_agent.sh"

CONF_DIR="$(dirname "$0")/../conf"
DEVFS_RULES="${CONF_DIR}/devfs-rules.conf"

# ==============================================================================
# setup: скопировать devfs-rules.conf в VM, перезагрузить devfs
# ==============================================================================
cmd_setup() {
    echo "=== devfs setup: копирование конфига в VM ==="

    if [ ! -f "$DEVFS_RULES" ]; then
        echo "ERROR: $DEVFS_RULES не найден" >&2
        exit 1
    fi

    # Копируем через 9p (mount /mnt/bsdos) в /etc/devfs.rules
    echo "Копирование devfs-rules.conf → /etc/devfs.rules..."
    agent_exec "cp /mnt/bsdos/infra/conf/devfs-rules.conf /etc/devfs.rules" || {
        echo "ERROR: не удалось скопировать devfs-rules.conf" >&2
        exit 1
    }

    # Перезагружаем devfs service
    echo "Перезагрузка devfs service..."
    agent_exec "service devfs restart" || {
        echo "WARNING: service devfs restart завершился с ошибкой (может быть нормально)" >&2
    }

    echo "+OK: devfs rulesets загружены"
}

# ==============================================================================
# apply: применить ruleset к конкретному jail
# ==============================================================================
cmd_apply() {
    local jail="${1:?usage: devfs-apply.sh apply JAIL RULESET}"
    local ruleset="${2:?usage: devfs-apply.sh apply JAIL RULESET}"

    echo "=== devfs apply: применение ruleset $ruleset к jail $jail ==="

    # Проверяем что jail существует
    if ! agent_check_jail "$jail" 2>/dev/null; then
        echo "ERROR: jail '$jail' не найден" >&2
        exit 1
    fi

    # Применяем ruleset через devfs rule applyset
    echo "Применение devfs rule applyset $jail $ruleset..."
    agent_exec "devfs rule applyset $jail $ruleset" || {
        echo "ERROR: devfs rule applyset $jail $ruleset не удалось" >&2
        exit 1
    }

    echo "+OK: ruleset $ruleset применён к $jail"
}

# ==============================================================================
# list: показать текущие rulesets (devfs rule show)
# ==============================================================================
cmd_list() {
    echo "=== devfs list: текущие rulesets ==="
    agent_exec "devfs rule show" || {
        echo "WARNING: devfs rule show завершился с ошибкой" >&2
        return 1
    }
}

# ==============================================================================
# status: показать какой ruleset у каких jail
# ==============================================================================
cmd_status() {
    echo "=== devfs status: rulesets по jail ==="

    # Получаем список jail через агент
    local jails
    jails=$(agent_exec "jls -h name" 2>/dev/null | grep -v '^name$' || true)

    if [ -z "$jails" ]; then
        echo "Нет активных jail"
        return 0
    fi

    # Для каждого jail показываем его devfs_ruleset из sysctl
    echo "Jail | devfs_ruleset"
    echo "----|---"
    while IFS= read -r jail; do
        if [ -z "$jail" ]; then
            continue
        fi
        local ruleset
        ruleset=$(agent_exec "sysctl -n jail.$jail.devfs_ruleset 2>/dev/null || echo 'N/A'" 2>/dev/null | head -1)
        printf '%-20s | %s\n' "$jail" "$ruleset"
    done <<EOF
$jails
EOF
}

# ==============================================================================
# main
# ==============================================================================
main() {
    local cmd="${1:-}"

    case "$cmd" in
        setup)
            cmd_setup
            ;;
        apply)
            shift || true
            cmd_apply "$@"
            ;;
        list)
            cmd_list
            ;;
        status)
            cmd_status
            ;;
        *)
            cat >&2 <<EOF
usage: $(basename "$0") <command>

Commands:
  setup                          Copy devfs-rules.conf to VM and reload devfs
  apply JAIL RULESET             Apply ruleset to specific jail
  list                           Show all loaded rulesets (devfs rule show)
  status                         Show which ruleset is set for each jail

Examples:
  $(basename "$0") setup
  $(basename "$0") apply appA 20
  $(basename "$0") list
  $(basename "$0") status

Rulesets:
  20 = bsdos_base (null, zero, random, fd, pts)
  21 = bsdos_audio (base + audio/mixer/snd)
  22 = bsdos_net (base + bpf, tun)
  23 = bsdos_full (net + audio)
EOF
            exit 1
            ;;
    esac
}

main "$@"
