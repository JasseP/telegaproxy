#!/usr/bin/env bash
###############################################################################
# lib/status.sh — сводный статус всей системы MTProxy (v2: multi-proxy)
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
# status_full — развёрнутый статус
# ─────────────────────────────────────────────────────────────────────────────
status_full() {
  echo ""
  echo "╔═════════════════════════════════════════════╗"
  echo "║         MTProxy Status (v3: multi-user)     ║"
  echo "╠═════════════════════════════════════════════╣"
  echo "║"

  # Контейнеры
  local running total
  running=$(count_running_proxies 2>/dev/null || echo "0")
  total=$(count_all_proxies 2>/dev/null || echo "0")
  echo "║  Контейнеры:     ${running}/${total} запущено"

  # Домены
  local domain_count
  if [[ -f "${DOMAINS_FILE}" ]]; then
    domain_count=$(domain_list_raw 2>/dev/null | wc -l)
  else
    domain_count=0
  fi
  echo "║  Доменов:        ${domain_count}"

  # Секреты
  local secret_total
  secret_total=$(secret_count 2>/dev/null || echo "0")
  echo "║  Секретов:       ${secret_total}"

  # Список доменов
  echo "║"
  if [[ -f "${DOMAINS_FILE}" ]] && (( domain_count > 0 )); then
    echo "║  Домены:"
    while IFS= read -r domain || [[ -n "$domain" ]]; do
      domain=$(printf '%s' "$domain" | tr -d '\r')
      [[ -z "$domain" ]] && continue
      [[ "$domain" == "domain" ]] && continue

      local cname cstatus port
      cname=$(container_name_for_domain "$domain")
      cstatus=$(docker_container_status "$cname")
      port=$(docker_container_port "$cname" || echo "-")

      local icon
      case "$cstatus" in
        running) icon="🟢" ;;
        stopped) icon="🟡" ;;
        none)    icon="🔴" ;;
      esac

      printf "║    %s %-18s %-8s port=%s\n" "$icon" "$domain" "$cstatus" "$port"
    done < "${DOMAINS_FILE}"
  else
    echo "║  Доменов: нет"
  fi

  echo "║"
  echo "╚═════════════════════════════════════════════╝"
}

# ─────────────────────────────────────────────────────────────────────────────
# status_compact — однострочный статус
# ─────────────────────────────────────────────────────────────────────────────
status_compact() {
  local running total domain_count
  running=$(count_running_proxies 2>/dev/null || echo "0")
  total=$(count_all_proxies 2>/dev/null || echo "0")
  domain_count=$(domain_list_raw 2>/dev/null | wc -l)

  local icon
  if (( running == 0 )); then
    icon="🔴"
  elif (( running == total )) && (( total > 0 )); then
    icon="🟢"
  else
    icon="🟡"
  fi

  printf '%s running=%d/%d domains=%d\n' "$icon" "$running" "$total" "$domain_count"
}
