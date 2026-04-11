#!/usr/bin/env bash
###############################################################################
# lib/monitor.sh — эвристический мониторинг (v4: один контейнер = один пользователь)
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/docker.sh
source "${MTPX_ROOT}/lib/docker.sh"

# ─────────────────────────────────────────────────────────────────────────────
# monitor_summary
# ─────────────────────────────────────────────────────────────────────────────
monitor_summary() {
  echo "┌──────────────────────────────────────────────────────────────────────┐"
  echo "│  Эвристический мониторинг                                            │"
  echo "├──────────────────────────────────────────────────────────────────────┤"

  printf "  %-4s %-30s %-8s %-6s %-7s %s\n" " " "Контейнер" "Статус" "Порт" "Errors" "Uptime"
  echo "  ──────────────────────────────────────────────────────────────────"

  local healthy_count=0 total_count=0

  docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^mtproto-' | while IFS= read -r cname; do
    local cstatus port errors="0" uptime="n/a"
    cstatus=$(docker_container_status "$cname")
    port=$(docker_container_port "$cname" 2>/dev/null || echo "-")

    if [[ "$cstatus" == "running" ]]; then
      # Ошибки в логах
      local recent_logs error_count
      recent_logs=$(docker logs --tail 100 "$cname" 2>&1 || true)
      error_count=$(echo "$recent_logs" | grep -ciE 'error|fatal|crash|segfault|panic' 2>/dev/null || true)
      error_count="${error_count:-0}"
      if (( error_count + 0 > 0 )); then
        errors="${error_count}"
      fi

      # Uptime
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

      healthy_count=$(( healthy_count + 1 ))
    fi

    total_count=$(( total_count + 1 ))

    local icon
    case "$cstatus" in
      running)
        if [[ "$errors" == "0" ]]; then icon="🟢"; else icon="🟡"; fi
        ;;
      stopped) icon="🟡" ;;
      none)    icon="🔴" ;;
    esac

    printf "  %s %-30s %-8s %-6s %-7s %s\n" "$icon" "$cname" "$cstatus" "$port" "$errors" "$uptime"
  done

  echo "└──────────────────────────────────────────────────────────────────────┘"
}

# ─────────────────────────────────────────────────────────────────────────────
# monitor_health
# ─────────────────────────────────────────────────────────────────────────────
monitor_health() {
  local total=0 running=0

  docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^mtproto-' | while IFS= read -r cname; do
    total=$(( total + 1 ))
    if docker_container_running "$cname"; then
      running=$(( running + 1 ))
    fi
  done

  if (( total == 0 )); then
    echo "none"
  elif (( running == total )); then
    echo "healthy"
  else
    echo "degraded"
  fi
}
