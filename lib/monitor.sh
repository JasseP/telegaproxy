#!/usr/bin/env bash
###############################################################################
# lib/monitor.sh — эвристический мониторинг MTProxy (v2: multi-proxy)
#
# Проверяет каждый домен по косвенным признакам:
#   1. Контейнер запущен?
#   2. Порт слушается?
#   3. Ошибки в логах?
#   4. Активные соединения?
#   5. Uptime?
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/docker.sh
source "${MTPX_ROOT}/lib/docker.sh"
# shellcheck source=lib/domain.sh
source "${MTPX_ROOT}/lib/domain.sh"

# ─────────────────────────────────────────────────────────────────────────────
# check_domain_health — проверка одного домена
# ─────────────────────────────────────────────────────────────────────────────
check_domain_health() {
  local domain="$1"
  local cname
  cname=$(container_name_for_domain "$domain")

  # Контейнер запущен?
  local cstatus
  cstatus=$(docker_container_status "$cname")

  # Порт
  local port port_ok
  port=$(docker_container_port "$cname" || echo "-")
  if [[ "$port" != "-" ]] && port_in_use "$port"; then
    port_ok=true
  else
    port_ok=false
  fi

  # Ошибки в логах
  local errors="clean"
  if docker_container_exists "$cname"; then
    local recent_logs error_count
    recent_logs=$(docker logs --tail 100 "$cname" 2>&1 || true)
    error_count=$(echo "$recent_logs" | grep -ciE 'error|fatal|crash|segfault|panic' 2>/dev/null || echo "0")
    if (( error_count > 0 )); then
      errors="${error_count}"
    fi
  fi

  # Uptime
  local uptime="n/a"
  if [[ "$cstatus" == "running" ]]; then
    local started started_epoch now uptime_seconds
    started=$(docker inspect --format '{{.State.StartedAt}}' "$cname" 2>/dev/null || echo "")
    if [[ -n "$started" ]]; then
      started_epoch=$(date -d "$started" +%s 2>/dev/null || date +%s)
      now=$(date +%s)
      uptime_seconds=$(( now - started_epoch ))
      if (( uptime_seconds > 0 )); then
        local hours=$(( uptime_seconds / 3600 ))
        local minutes=$(( (uptime_seconds % 3600) / 60 ))
        uptime="${hours}h${minutes}m"
      fi
    fi
  fi

  # Вывод
  local icon
  case "$cstatus" in
    running) icon="🟢" ;;
    stopped) icon="🟡" ;;
    none)    icon="🔴" ;;
  esac

  printf "  %s %-18s %-8s port=%-5s errors=%-5s uptime=%s\n" \
    "$icon" "$domain" "$cstatus" "$port" "$errors" "$uptime"
}

# ─────────────────────────────────────────────────────────────────────────────
# monitor_summary — таблица всех доменов
# ─────────────────────────────────────────────────────────────────────────────
monitor_summary() {
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    log_error "Нет доменов"
    return 1
  fi

  echo "┌──────────────────────────────────────────────────────────────────────┐"
  echo "│  Эвристический мониторинг                                            │"
  echo "├──────────────────────────────────────────────────────────────────────┤"

  printf "  %-4s %-18s %-8s %-7s %-7s %s\n" " " "Домен" "Статус" "Порт" "Errors" "Uptime"
  echo "  ──────────────────────────────────────────────────────────────────"

  local healthy_count=0 total_count=0

  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue

    check_domain_health "$domain"

    total_count=$(( total_count + 1 ))
    local cname
    cname=$(container_name_for_domain "$domain")
    if docker_container_running "$cname"; then
      healthy_count=$(( healthy_count + 1 ))
    fi
  done < "${DOMAINS_FILE}"

  echo "├──────────────────────────────────────────────────────────────────────┤"
  printf "  Запущено: %d/%d\n" "$healthy_count" "$total_count"
  echo "└──────────────────────────────────────────────────────────────────────┘"
}

# ─────────────────────────────────────────────────────────────────────────────
# monitor_health — общий вердикт
# ─────────────────────────────────────────────────────────────────────────────
# healthy  — все домены запущены
# degraded — хотя бы один не запущен
# none     — нет доменов
# ─────────────────────────────────────────────────────────────────────────────
monitor_health() {
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    echo "none"
    return
  fi

  local total=0 running=0
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue

    total=$(( total + 1 ))
    local cname
    cname=$(container_name_for_domain "$domain")
    if docker_container_running "$cname"; then
      running=$(( running + 1 ))
    fi
  done < "${DOMAINS_FILE}"

  if (( total == 0 )); then
    echo "none"
  elif (( running == total )); then
    echo "healthy"
  else
    echo "degraded"
  fi
}
