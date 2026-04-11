#!/usr/bin/env bash
###############################################################################
# lib/metrics.sh — сбор и хранение метрик MTProxy (v4: per-user контейнеры)
#
# Архитектура:
#   state/metrics/raw/<user>-<domain>/YYYY-MM-DD.csv
#     → raw-метрики каждые 5 минут
#   state/metrics/daily/<user>-<domain>/YYYY-MM-DD.csv
#     → daily aggregates
#
# Формат raw-метрик:
#   timestamp,connections_now,rx_bytes,tx_bytes,unique_ips_now,status
#
# Формат daily aggregates:
#   date,connections_peak,connections_avg,rx_mb_day,tx_mb_day,total_mb_day,
#   active_intervals_count,night_active_intervals,unique_ips_day,
#   ip_changes_day,active_minutes_day,estimated_devices_peak
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/docker.sh
source "${MTPX_ROOT}/lib/docker.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Пути
# ─────────────────────────────────────────────────────────────────────────────
METRICS_DIR="${STATE_DIR}/metrics"
METRICS_RAW_DIR="${METRICS_DIR}/raw"
METRICS_DAILY_DIR="${METRICS_DIR}/daily"

# ─────────────────────────────────────────────────────────────────────────────
# Инициализация
# ─────────────────────────────────────────────────────────────────────────────
metrics_init() {
  mkdir -p "${METRICS_RAW_DIR}" "${METRICS_DAILY_DIR}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
_metric_key() {
  local username="$1"
  local domain="$2"
  local norm
  norm=$(normalize_domain "$domain")
  printf '%s-%s' "$username" "$norm"
}

_raw_dir() {
  local key="$1"
  local dir="${METRICS_RAW_DIR}/${key}"
  mkdir -p "$dir"
  echo "$dir"
}

_daily_dir() {
  local key="$1"
  local dir="${METRICS_DAILY_DIR}/${key}"
  mkdir -p "$dir"
  echo "$dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# collect_tick — собрать одну raw-метрику для пользователя на домене
# ─────────────────────────────────────────────────────────────────────────────
# collect_tick <username> <domain>
#
# Собирает метрики из контейнера:
#   • connections_now — активные TCP-соединения
#   • rx_bytes / tx_bytes — трафик контейнера (docker stats)
#   • unique_ips_now — уникальные IP (через ss)
#   • status — running/stopped/none
#
# Записывает в state/metrics/raw/<user>-<domain>/YYYY-MM-DD.csv
# ─────────────────────────────────────────────────────────────────────────────
collect_tick() {
  local username="$1"
  local domain="$2"

  local key cname rdir date today_file
  key=$(_metric_key "$username" "$domain")
  cname=$(container_name_for "$domain" "$username")
  rdir=$(_raw_dir "$key")
  date=$(date -u +%Y-%m-%d)
  today_file="${rdir}/${date}.csv"

  local timestamp="now"
  local connections_now=0
  local rx_bytes=0
  local tx_bytes=0
  local unique_ips_now=0
  local cstatus
  cstatus=$(docker_container_status "$cname")

  if [[ "$cstatus" == "running" ]]; then
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # PID контейнера
    local pid
    pid=$(docker inspect --format '{{.State.Pid}}' "$cname" 2>/dev/null || echo "0")

    if [[ "$pid" != "0" ]] && [[ -n "$pid" ]]; then
      # Активные соединения
      connections_now=$(ss -tnp 2>/dev/null | grep -c "pid=${pid}" 2>/dev/null || echo "0")

      # Уникальные IP
      unique_ips_now=$(ss -tnp 2>/dev/null | grep "pid=${pid}" 2>/dev/null | awk '{print $5}' | cut -d':' -f1 | sort -u | grep -c '.' 2>/dev/null || echo "0")
    fi

    # Трафик через /proc/<pid>/net/dev (или docker stats --no-stream)
    if [[ "$pid" != "0" ]] && [[ -n "$pid" ]] && [[ -d "/proc/${pid}" ]]; then
      rx_bytes=$(docker inspect --format='{{.NetworkSettings.Networks}}' "$cname" 2>/dev/null | grep -oP '"rx_bytes":\s*\K[0-9]+' | head -1 || echo "0")
      tx_bytes=$(docker inspect --format='{{.NetworkSettings.Networks}}' "$cname" 2>/dev/null | grep -oP '"tx_bytes":\s*\K[0-9]+' | head -1 || echo "0")
    fi

    # Fallback: docker stats (дорогой, но надёжный)
    if [[ "$rx_bytes" == "0" ]] || [[ -z "$rx_bytes" ]]; then
      local stats_line
      stats_line=$(docker stats --no-stream --format '{{.MemUsage}}' "$cname" 2>/dev/null || echo "")
      # Docker stats не даёт bytes напрямую — используем inspect
      rx_bytes=$(docker inspect "$cname" 2>/dev/null | grep -oP '"rx_bytes":\s*\K[0-9]+' | head -1 || echo "0")
      tx_bytes=$(docker inspect "$cname" 2>/dev/null | grep -oP '"tx_bytes":\s*\K[0-9]+' | head -1 || echo "0")
    fi
  fi

  [[ -z "$rx_bytes" ]] && rx_bytes=0
  [[ -z "$tx_bytes" ]] && tx_bytes=0

  # Записываем raw-метрику (атомарно для сегодняшнего файла)
  local tmp
  tmp="$(mktemp "${today_file}.tmp.XXXXXX")"
  if [[ -f "$today_file" ]]; then
    cat "$today_file" > "$tmp"
  else
    echo "timestamp,connections_now,rx_bytes,tx_bytes,unique_ips_now,status" > "$tmp"
  fi
  printf '%s,%s,%s,%s,%s,%s\n' \
    "$timestamp" "$connections_now" "$rx_bytes" "$tx_bytes" "$unique_ips_now" "$cstatus" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$today_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# collect_all_ticks — собрать метрики для всех пользователей и доменов
# ─────────────────────────────────────────────────────────────────────────────
collect_all_ticks() {
  if [[ ! -f "${USERS_FILE}" ]] || [[ ! -f "${DOMAINS_FILE}" ]]; then
    return 0
  fi

  while IFS=',' read -r uid username created status comment; do
    [[ "$status" != "active" ]] && continue
    while IFS= read -r domain || [[ -n "$domain" ]]; do
      domain=$(printf '%s' "$domain" | tr -d '\r')
      [[ -z "$domain" ]] && continue
      [[ "$domain" == "domain" ]] && continue

      collect_tick "$username" "$domain"
    done < "${DOMAINS_FILE}"
  done < <(tail -n +2 "${USERS_FILE}")
}

# ─────────────────────────────────────────────────────────────────────────────
# build_daily_aggregate — построить daily aggregate из raw-метрик
# ─────────────────────────────────────────────────────────────────────────────
# build_daily_aggregate <username> <domain> <date>
#
# Читает raw-метрику за день, строит aggregate:
#   connections_peak, connections_avg, rx_mb_day, tx_mb_day, total_mb_day,
#   active_intervals_count, night_active_intervals, unique_ips_day,
#   ip_changes_day, active_minutes_day, estimated_devices_peak
# ─────────────────────────────────────────────────────────────────────────────
build_daily_aggregate() {
  local username="$1"
  local domain="$2"
  local date="$3"

  local key rdir ddir raw_file daily_file
  key=$(_metric_key "$username" "$domain")
  rdir=$(_raw_dir "$key")
  ddir=$(_daily_dir "$key")
  raw_file="${rdir}/${date}.csv"
  daily_file="${ddir}/${date}.csv"

  if [[ ! -f "$raw_file" ]]; then
    return 0
  fi

  # Парсим raw-метрику через awk
  local result
  result=$(tail -n +2 "$raw_file" | awk -F',' '
  BEGIN {
    conn_peak=0; conn_sum=0; conn_count=0
    rx_max=0; tx_max=0
    active_intervals=0; night_intervals=0
    unique_ips_max=0; prev_ips=0; ip_changes=0
    active_minutes=0; running_count=0
  }
  {
    ts=$1; conn=$2; rx=$3; tx=$4; ips=$5; st=$6
    if (conn+0 > conn_peak) conn_peak = conn+0
    conn_sum += conn+0
    conn_count++
    if (rx+0 > rx_max) rx_max = rx+0
    if (tx+0 > tx_max) tx_max = tx+0
    if (ips+0 > unique_ips_max) unique_ips_max = ips+0
    if (prev_ips > 0 && ips+0 != prev_ips) ip_changes++
    prev_ips = ips+0
    if (st == "running") {
      running_count++
      active_intervals++
      # Ночь: 00:00-06:00 UTC
      if (ts ~ /T0[0-5]:/) night_intervals++
    }
  }
  END {
    conn_avg = (conn_count > 0) ? conn_sum / conn_count : 0
    rx_mb = rx_max / 1048576
    tx_mb = tx_max / 1048576
    total_mb = rx_mb + tx_mb
    active_min = active_intervals * 5
    # estimated_devices_peak: уникальные IP / 2 (грубая оценка)
    est_devices = (unique_ips_max > 0) ? int((unique_ips_max + 1) / 2) : 0
    if (est_devices < 1 && active_intervals > 0) est_devices = 1
    printf "%d,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%d",
      conn_peak, conn_avg, rx_mb, tx_mb, total_mb,
      active_intervals, night_intervals, unique_ips_max, ip_changes,
      active_min, est_devices
  }')

  if [[ -z "$result" ]]; then
    return 0
  fi

  # Записываем daily aggregate
  local tmp
  tmp="$(mktemp "${daily_file}.tmp.XXXXXX")"
  echo "date,connections_peak,connections_avg,rx_mb_day,tx_mb_day,total_mb_day,active_intervals_count,night_active_intervals,unique_ips_day,ip_changes_day,active_minutes_day,estimated_devices_peak" > "$tmp"
  printf '%s,%s\n' "$date" "$result" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$daily_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# build_all_daily — построить daily aggregates для всех
# ─────────────────────────────────────────────────────────────────────────────
build_all_daily() {
  local date="${1:-$(date -u +%Y-%m-%d)}"

  if [[ ! -f "${USERS_FILE}" ]] || [[ ! -f "${DOMAINS_FILE}" ]]; then
    return 0
  fi

  while IFS=',' read -r uid username created status comment; do
    [[ "$status" != "active" ]] && continue
    while IFS= read -r domain || [[ -n "$domain" ]]; do
      domain=$(printf '%s' "$domain" | tr -d '\r')
      [[ -z "$domain" ]] && continue
      [[ "$domain" == "domain" ]] && continue

      build_daily_aggregate "$username" "$domain" "$date"
    done < "${DOMAINS_FILE}"
  done < <(tail -n +2 "${USERS_FILE}")
}

# ─────────────────────────────────────────────────────────────────────────────
# get_daily_metric — прочитать daily aggregate
# ─────────────────────────────────────────────────────────────────────────────
get_daily_metric() {
  local username="$1"
  local domain="$2"
  local date="$3"
  local field="$4"  # connections_peak, total_mb_day, и т.д.

  local key ddir daily_file
  key=$(_metric_key "$username" "$domain")
  ddir=$(_daily_dir "$key")
  daily_file="${ddir}/${date}.csv"

  if [[ ! -f "$daily_file" ]]; then
    echo "0"
    return
  fi

  # Поля: date,connections_peak,connections_avg,rx_mb_day,tx_mb_day,total_mb_day,
  #        active_intervals_count,night_active_intervals,unique_ips_day,
  #        ip_changes_day,active_minutes_day,estimated_devices_peak
  local col
  case "$field" in
    connections_peak) col=2 ;;
    connections_avg) col=3 ;;
    rx_mb_day) col=4 ;;
    tx_mb_day) col=5 ;;
    total_mb_day) col=6 ;;
    active_intervals_count) col=7 ;;
    night_active_intervals) col=8 ;;
    unique_ips_day) col=9 ;;
    ip_changes_day) col=10 ;;
    active_minutes_day) col=11 ;;
    estimated_devices_peak) col=12 ;;
    *) echo "0"; return ;;
  esac

  tail -n +2 "$daily_file" | head -1 | cut -d',' -f"$col"
}

# ─────────────────────────────────────────────────────────────────────────────
# get_baseline_14d — среднее за 14 дней до даты
# ─────────────────────────────────────────────────────────────────────────────
get_baseline_14d() {
  local username="$1"
  local domain="$2"
  local date="$3"
  local field="$4"

  local key ddir
  key=$(_metric_key "$username" "$domain")
  ddir=$(_daily_dir "$key")

  # Собираем значения за 14 дней до date
  local sum=0 count=0
  local target_epoch
  target_epoch=$(date -d "$date" +%s 2>/dev/null || date +%s)

  for i in $(seq 1 14); do
    local check_epoch check_date
    check_epoch=$(( target_epoch - i * 86400 ))
    check_date=$(date -d "@${check_epoch}" +%Y-%m-%d 2>/dev/null || echo "")
    [[ -z "$check_date" ]] && continue

    local daily_file="${ddir}/${check_date}.csv"
    if [[ -f "$daily_file" ]]; then
      local val
      val=$(get_daily_metric "$username" "$domain" "$check_date" "$field")
      if [[ -n "$val" ]] && [[ "$val" != "0" ]]; then
        sum=$(echo "$sum + $val" | bc 2>/dev/null || echo "$sum")
        count=$(( count + 1 ))
      fi
    fi
  done

  if (( count > 0 )); then
    echo "$sum / $count" | bc 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# get_raw_file — получить путь к raw-файлу
# ─────────────────────────────────────────────────────────────────────────────
get_raw_file() {
  local username="$1"
  local domain="$2"
  local date="$3"

  local key rdir
  key=$(_metric_key "$username" "$domain")
  rdir=$(_raw_dir "$key")
  echo "${rdir}/${date}.csv"
}

# ─────────────────────────────────────────────────────────────────────────────
# get_daily_file — получить путь к daily-файлу
# ─────────────────────────────────────────────────────────────────────────────
get_daily_file() {
  local username="$1"
  local domain="$2"
  local date="$3"

  local key ddir
  key=$(_metric_key "$username" "$domain")
  ddir=$(_daily_dir "$key")
  echo "${ddir}/${date}.csv"
}
