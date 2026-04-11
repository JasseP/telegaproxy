#!/usr/bin/env bash
###############################################################################
# lib/status.sh — сводный статус (v4: один контейнер = один пользователь)
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${MTPX_ROOT}/lib/config.sh"
# shellcheck source=lib/secret.sh
source "${MTPX_ROOT}/lib/secret.sh"
# shellcheck source=lib/docker.sh
source "${MTPX_ROOT}/lib/docker.sh"
# shellcheck source=lib/domain.sh
source "${MTPX_ROOT}/lib/domain.sh"

# ─────────────────────────────────────────────────────────────────────────────
# status_full
# ─────────────────────────────────────────────────────────────────────────────
status_full() {
  echo ""
  echo "╔═════════════════════════════════════════════╗"
  echo "║         MTProxy Status (v4: multi-user)     ║"
  echo "╠═════════════════════════════════════════════╣"
  echo "║"

  # Контейнеры
  local running total
  running=$(count_running_proxies 2>/dev/null || echo "0")
  total=$(count_all_proxies 2>/dev/null || echo "0")
  echo "║  Контейнеры:     ${running}/${total} запущено"

  # Домены
  local domain_count=0
  if [[ -f "${DOMAINS_FILE}" ]]; then
    domain_count=$(domain_list_raw 2>/dev/null | wc -l)
  fi
  echo "║  Доменов:        ${domain_count}"

  # Пользователи
  local user_count=0
  if [[ -f "${USERS_FILE}" ]]; then
    user_count=$(active_users 2>/dev/null | wc -l)
  fi
  echo "║  Пользователей:  ${user_count}"

  # Список контейнеров
  echo "║"
  if (( total > 0 )); then
    echo "║  Контейнеры:"
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^mtproto-' | while IFS= read -r cname; do
      local cstatus port
      cstatus=$(docker_container_status "$cname")
      port=$(docker_container_port "$cname" 2>/dev/null || echo "-")

      local icon
      case "$cstatus" in
        running) icon="🟢" ;;
        stopped) icon="🟡" ;;
        none)    icon="🔴" ;;
      esac

      # Извлекаем домен и пользователя из имени
      # mtproto-ya-ru-alice → domain=ya.ru, user=alice
      local rest="${cname#mtproto-}"
      local user="${rest##*-}"
      local domain_norm="${rest%-*}"
      # domain_norm = ya-ru → ya.ru
      local domain="${domain_norm//-/.}"

      printf "║    %s %-16s user=%-10s %-8s port=%s\n" "$icon" "$domain" "$user" "$cstatus" "$port"
    done
  else
    echo "║  Контейнеров: нет"
  fi

  echo "║"
  echo "╚═════════════════════════════════════════════╝"
}

# ─────────────────────────────────────────────────────────────────────────────
# status_compact
# ─────────────────────────────────────────────────────────────────────────────
status_compact() {
  local running total domain_count user_count
  running=$(count_running_proxies 2>/dev/null || echo "0")
  total=$(count_all_proxies 2>/dev/null || echo "0")
  domain_count=$(domain_list_raw 2>/dev/null | wc -l)
  user_count=$(active_users 2>/dev/null | wc -l)

  local icon
  if (( running == 0 )); then
    icon="🔴"
  elif (( running == total )) && (( total > 0 )); then
    icon="🟢"
  else
    icon="🟡"
  fi

  printf '%s running=%d/%d domains=%d users=%d\n' \
    "$icon" "$running" "$total" "$domain_count" "$user_count"
}
