#!/usr/bin/env bash
###############################################################################
# lib/alerts.sh — обнаружение аномалий (v4: per-user контейнеры)
#
# Цель: не доказывать утечку, а находить аномальные дни и подсказывать
# администратору, кого и за какую дату проверить.
#
# Правила алерта v1 (день = suspicious при 2+ сработках):
#   1. total_mb_day >= avg_14d * 3
#   2. connections_peak >= avg_14d * 2.5
#   3. night_active_intervals >= avg_14d * 3
#   4. unique_ips_day >= avg_14d * 3 И unique_ips_day >= 3
#
# Статусы метрик:
#   ok          — в пределах нормы
#   watch       — отклонение 2-3x
#   suspicious  — отклонение >= 3x
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/metrics.sh
source "${MTPX_ROOT}/lib/metrics.sh"

# ─────────────────────────────────────────────────────────────────────────────
# check_one_day — проверить один день пользователя на аномалии
# ─────────────────────────────────────────────────────────────────────────────
# Возвращает:
#   alert_lines[] — список сработавших правил
#   metrics[]     — статусы всех метрик
# ─────────────────────────────────────────────────────────────────────────────
check_one_day() {
  local username="$1"
  local domain="$2"
  local date="$3"

  local rules_triggered=0
  local alert_lines=()
  local metric_statuses=()

  # Проверяем наличие daily aggregate
  local daily_file
  daily_file=$(get_daily_file "$username" "$domain" "$date")
  if [[ ! -f "$daily_file" ]]; then
    echo "no_data"
    return
  fi

  # Собираем метрики
  local total_mb connections_peak night_intervals unique_ips
  total_mb=$(get_daily_metric "$username" "$domain" "$date" "total_mb_day")
  connections_peak=$(get_daily_metric "$username" "$domain" "$date" "connections_peak")
  night_intervals=$(get_daily_metric "$username" "$domain" "$date" "night_active_intervals")
  unique_ips=$(get_daily_metric "$username" "$domain" "$date" "unique_ips_day")

  # Базлайны за 14 дней
  local avg_mb avg_conn avg_night avg_ips
  avg_mb=$(get_baseline_14d "$username" "$domain" "$date" "total_mb_day")
  avg_conn=$(get_baseline_14d "$username" "$domain" "$date" "connections_peak")
  avg_night=$(get_baseline_14d "$username" "$domain" "$date" "night_active_intervals")
  avg_ips=$(get_baseline_14d "$username" "$domain" "$date" "unique_ips_day")

  # Правило 1: total_mb_day >= avg_14d * 3
  local mb_status="ok"
  if [[ "$avg_mb" != "0" ]] && [[ -n "$avg_mb" ]]; then
    local mb_ratio
    mb_ratio=$(echo "scale=2; $total_mb / $avg_mb" | bc 2>/dev/null || echo "0")
    local mb_check
    mb_check=$(echo "$mb_ratio >= 3" | bc 2>/dev/null || echo "0")
    if [[ "$mb_check" == "1" ]]; then
      alert_lines+=("  📊 Трафик: ${total_mb} MB (норма: ${avg_mb} MB, отклонение: ${mb_ratio}x)")
      mb_status="suspicious"
      rules_triggered=$(( rules_triggered + 1 ))
    else
      local mb_watch
      mb_watch=$(echo "$mb_ratio >= 2" | bc 2>/dev/null || echo "0")
      if [[ "$mb_watch" == "1" ]]; then
        mb_status="watch"
      fi
    fi
  fi
  metric_statuses+=("total_mb_day:${total_mb}:${avg_mb}:${mb_status}")

  # Правило 2: connections_peak >= avg_14d * 2.5
  local conn_status="ok"
  if [[ "$avg_conn" != "0" ]] && [[ -n "$avg_conn" ]]; then
    local conn_ratio
    conn_ratio=$(echo "scale=2; $connections_peak / $avg_conn" | bc 2>/dev/null || echo "0")
    local conn_check
    conn_check=$(echo "$conn_ratio >= 2.5" | bc 2>/dev/null || echo "0")
    if [[ "$conn_check" == "1" ]]; then
      alert_lines+=("  🔌 Пики соединений: ${connections_peak} (норма: ${avg_conn}, отклонение: ${conn_ratio}x)")
      conn_status="suspicious"
      rules_triggered=$(( rules_triggered + 1 ))
    else
      local conn_watch
      conn_watch=$(echo "$conn_ratio >= 2" | bc 2>/dev/null || echo "0")
      if [[ "$conn_watch" == "1" ]]; then
        conn_status="watch"
      fi
    fi
  fi
  metric_statuses+=("connections_peak:${connections_peak}:${avg_conn}:${conn_status}")

  # Правило 3: night_active_intervals >= avg_14d * 3
  local night_status="ok"
  if [[ "$avg_night" != "0" ]] && [[ -n "$avg_night" ]]; then
    local night_ratio
    night_ratio=$(echo "scale=2; $night_intervals / $avg_night" | bc 2>/dev/null || echo "0")
    local night_check
    night_check=$(echo "$night_ratio >= 3" | bc 2>/dev/null || echo "0")
    if [[ "$night_check" == "1" ]]; then
      alert_lines+=("  🌙 Ночная активность: ${night_intervals} интервалов (норма: ${avg_night}, отклонение: ${night_ratio}x)")
      night_status="suspicious"
      rules_triggered=$(( rules_triggered + 1 ))
    else
      local night_watch
      night_watch=$(echo "$night_ratio >= 2" | bc 2>/dev/null || echo "0")
      if [[ "$night_watch" == "1" ]]; then
        night_status="watch"
      fi
    fi
  fi
  metric_statuses+=("night_active:${night_intervals}:${avg_night}:${night_status}")

  # Правило 4: unique_ips_day >= avg_14d * 3 И unique_ips_day >= 3
  local ips_status="ok"
  if [[ "$avg_ips" != "0" ]] && [[ -n "$avg_ips" ]]; then
    local ips_ratio
    ips_ratio=$(echo "scale=2; $unique_ips / $avg_ips" | bc 2>/dev/null || echo "0")
    local ips_check_ratio
    ips_check_ratio=$(echo "$ips_ratio >= 3" | bc 2>/dev/null || echo "0")
    local ips_check_min
    ips_check_min=$(echo "$unique_ips >= 3" | bc 2>/dev/null || echo "0")
    if [[ "$ips_check_ratio" == "1" ]] && [[ "$ips_check_min" == "1" ]]; then
      alert_lines+=("  🌐 Уникальные IP: ${unique_ips} (норма: ${avg_ips}, отклонение: ${ips_ratio}x)")
      ips_status="suspicious"
      rules_triggered=$(( rules_triggered + 1 ))
    else
      local ips_watch
      ips_watch=$(echo "$ips_ratio >= 2" | bc 2>/dev/null || echo "0")
      if [[ "$ips_watch" == "1" ]]; then
        ips_status="watch"
      fi
    fi
  fi
  metric_statuses+=("unique_ips:${unique_ips}:${avg_ips}:${ips_status}")

  # Вывод результатов
  if (( rules_triggered >= 2 )); then
    echo "SUSPICIOUS"
    for line in "${alert_lines[@]}"; do
      echo "$line"
    done
  elif (( rules_triggered == 1 )); then
    echo "WATCH"
    for line in "${alert_lines[@]}"; do
      echo "$line"
    done
  else
    echo "OK"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# check_all_alerts — проверить все дни всех пользователей
# ─────────────────────────────────────────────────────────────────────────────
check_all_alerts() {
  local today
  today=$(date -u +%Y-%m-%d)

  local alerts_found=0

  echo "┌──────────────────────────────────────────────────────────────────┐"
  echo "│  Проверка аномалий                                               │"
  echo "├──────────────────────────────────────────────────────────────────┤"

  if [[ ! -f "${USERS_FILE}" ]] || [[ ! -f "${DOMAINS_FILE}" ]]; then
    echo "│  Нет данных                                                     │"
    echo "└──────────────────────────────────────────────────────────────────┘"
    return 0
  fi

  # Проверяем последние 7 дней
  for days_ago in $(seq 0 7); do
    local check_epoch check_date
    check_epoch=$(($(date -u +%s) - days_ago * 86400))
    check_date=$(date -u -d "@${check_epoch}" +%Y-%m-%d 2>/dev/null || echo "")
    [[ -z "$check_date" ]] && continue

    while IFS=',' read -r uid username created status comment; do
      [[ "$status" != "active" ]] && continue
      [[ -z "$uid" ]] && continue

      while IFS= read -r domain || [[ -n "$domain" ]]; do
        domain=$(printf '%s' "$domain" | tr -d '\r')
        [[ -z "$domain" ]] && continue
        [[ "$domain" == "domain" ]] && continue

        local result
        result=$(check_one_day "$username" "$domain" "$check_date")
        local level
        level=$(echo "$result" | head -1)

        if [[ "$level" == "SUSPICIOUS" ]]; then
          alerts_found=$(( alerts_found + 1 ))
          echo "│"
          echo "│  ⚠️  Проверь: ${username} @ ${domain} за ${check_date}"
          echo "$result" | tail -n +2 | while IFS= read -r line; do
            printf "│    %s\n" "$line"
          done
          echo "│"
        fi
      done < "${DOMAINS_FILE}"
    done < <(tail -n +2 "${USERS_FILE}")
  done

  if (( alerts_found == 0 )); then
    echo "│  ✅ Странной активности не обнаружено                         │"
  fi

  echo "└──────────────────────────────────────────────────────────────────┘"
}

# ─────────────────────────────────────────────────────────────────────────────
# monitoring_detail — детальная таблица для одного пользователя/домена/даты
# ─────────────────────────────────────────────────────────────────────────────
monitoring_detail() {
  local username="$1"
  local domain="$2"
  local date="$3"

  local daily_file
  daily_file=$(get_daily_file "$username" "$domain" "$date")
  if [[ ! -f "$daily_file" ]]; then
    log_error "Нет данных для ${username} @ ${domain} за ${date}"
    return 1
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════════╗"
  echo "║  Мониторинг: ${username} @ ${domain} — ${date}"
  echo "╠══════════════════════════════════════════════════════════════════════╣"
  echo ""

  # Заголовки таблицы
  printf "  %-25s │ %10s │ %10s │ %8s │ %s\n" "Метрика" "14д avg" "Событие" "Отклон." "Статус"
  echo "  ─────────────────────────┼────────────┼────────────┼──────────┼──────────"

  local metrics=("total_mb_day" "connections_peak" "night_active_intervals" "unique_ips_day")
  local labels=("Трафик (MB)" "Пик соединений" "Ночные интервалы" "Уникальные IP")
  local thresholds=("3" "2.5" "3" "3")

  for i in "${!metrics[@]}"; do
    local metric="${metrics[$i]}"
    local label="${labels[$i]}"
    local threshold="${thresholds[$i]}"

    local event_val avg_val
    event_val=$(get_daily_metric "$username" "$domain" "$date" "$metric")
    avg_val=$(get_baseline_14d "$username" "$domain" "$date" "$metric")

    local ratio="—"
    local status="ok"

    if [[ "$avg_val" != "0" ]] && [[ -n "$avg_val" ]] && [[ -n "$event_val" ]]; then
      ratio=$(echo "scale=2; $event_val / $avg_val" | bc 2>/dev/null || echo "—")
      if [[ "$ratio" != "—" ]]; then
        local check
        check=$(echo "$ratio >= $threshold" | bc 2>/dev/null || echo "0")
        if [[ "$check" == "1" ]]; then
          status="suspicious"
        else
          local watch_check
          watch_check=$(echo "$ratio >= 2" | bc 2>/dev/null || echo "0")
          if [[ "$watch_check" == "1" ]]; then
            status="watch"
          fi
        fi
      fi
    fi

    local status_icon
    case "$status" in
      ok) status_icon="✅" ;;
      watch) status_icon="⚠️" ;;
      suspicious) status_icon="🔴" ;;
      *) status_icon="?" ;;
    esac

    printf "  %-25s │ %10s │ %10s │ %7sx │ %s %s\n" \
      "$label" "$avg_val" "$event_val" "$ratio" "$status_icon" "$status"
  done

  echo ""
  echo "  Статусы: ✅ ok | ⚠️ watch (2-3x) | 🔴 suspicious (>= ${threshold}x)"
  echo ""

  # Статус онлайн
  local key cname
  key=$(_metric_key "$username" "$domain")
  cname=$(container_name_for "$domain" "$username")
  local cstatus
  cstatus=$(docker_container_status "$cname" 2>/dev/null || echo "unknown")

  local online_status="inactive"
  if [[ "$cstatus" == "running" ]]; then
    # Проверяем raw-метрики за последний час
    local raw_file
    raw_file=$(get_raw_file "$username" "$domain" "$(date -u +%Y-%m-%d)")
    if [[ -f "$raw_file" ]]; then
      local last_entry
      last_entry=$(tail -1 "$raw_file")
      local last_ts last_status
      last_ts=$(echo "$last_entry" | cut -d',' -f1)
      last_status=$(echo "$last_entry" | cut -d',' -f6)
      if [[ "$last_status" == "running" ]]; then
        # Проверяем, что запись не старше часа
        local last_epoch now_epoch
        last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo "0")
        now_epoch=$(date -u +%s)
        local diff=$(( now_epoch - last_epoch ))
        if (( diff < 3600 )); then
          online_status="online_now"
        elif (( diff < 86400 )); then
          online_status="active_recently"
        fi
      fi
    fi
  fi

  echo "  Онлайн-статус: ${online_status}"
  echo "  Контейнер: ${cname} (${cstatus})"
  echo "╚══════════════════════════════════════════════════════════════════════╝"
}
