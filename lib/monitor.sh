#!/usr/bin/env bash
###############################################################################
# lib/monitor.sh — эвристический мониторинг MTProxy
#
# «Эвристический» означает: мы НЕ подключаются к прокси напрямую и не
# проверяем его протокол. Вместо этого собираем косвенные признаки:
#   1. Работает ли Docker-контейнер?                    (check_process)
#   2. Есть ли ошибки в недавних логах?                 (check_errors_in_logs)
#   3. Есть ли активные сетевые соединения?             (check_connections)
#   4. Слушается ли ожидаемый порт?                     (check_port_listening)
#   5. Сколько времени контейнер работает?              (check_uptime)
#
# По совокупности этих признаков определяем «здоровье» системы:
#   healthy   — всё в порядке
#   degraded  — есть проблемы (контейнер упал, порт не слушается, ошибки)
#
# Зачем? Чтобы быстро понять, жив ли прокси, без подключения клиента.
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/docker.sh
source "${MTPX_ROOT}/lib/docker.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Эвристики — отдельные функции для независимой проверки каждого признака
# ─────────────────────────────────────────────────────────────────────────────

# ── check_process — жив ли процесс контейнера ────────────────────────────────
# Просто проверяем, running ли контейнер.
# Возвращает: "ok" или "fail"
# ─────────────────────────────────────────────────────────────────────────────
check_process() {
  if container_running; then
    echo "ok"
  else
    echo "fail"
  fi
}

# ── check_errors_in_logs — есть ли ошибки в логах ───────────────────────────
# Берём последние 100 строк логов и ищем паттерны ошибок:
#   error, fatal, crash, segfault, panic
# -i — регистронезависимый поиск.
# Возвращает:
#   "no_container"      — контейнер не существует
#   "errors_found:<n>"  — найдено n строк с ошибками
#   "clean"             — ошибок нет
# ─────────────────────────────────────────────────────────────────────────────
check_errors_in_logs() {
  if ! container_exists; then
    echo "no_container"
    return
  fi

  local recent_logs
  recent_logs=$(docker logs --tail 100 "${CONTAINER_NAME}" 2>&1 || true)

  # Считаем строки, содержащие паттерны ошибок
  local error_count=0
  error_count=$(echo "$recent_logs" | grep -ciE 'error|fatal|crash|segfault|panic' 2>/dev/null || echo "0")

  if (( error_count > 0 )); then
    echo "errors_found:${error_count}"
  else
    echo "clean"
  fi
}

# ── check_connections — есть ли активные подключения ────────────────────────
# Проверяем сетевые соединения процесса контейнера.
# Алгоритм:
#   1. Получаем PID контейнера через docker inspect
#   2. Через ss -tnp ищем соединения этого PID
#   3. Считаем количество
#
# Это косвенный признак: если есть соединения — прокси точно работает
# и обслуживает клиентов. Если нет — может быть просто без нагрузки.
#
# Возвращает:
#   "no_container" — контейнер не существует
#   "unknown"      — не удалось определить PID
#   "active:<n>"   — n активных соединений
#   "idle"         — соединений нет
# ─────────────────────────────────────────────────────────────────────────────
check_connections() {
  if ! container_running; then
    echo "no_container"
    return
  fi

  # Получаем PID контейнера (основного процесса)
  local pid
  pid=$(docker inspect --format '{{.State.Pid}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
  if [[ -z "$pid" ]] || [[ "$pid" == "0" ]]; then
    echo "unknown"
    return
  fi

  # Считаем TCP-соединения процесса
  local conn_count=0
  if command -v ss &>/dev/null; then
    # ss -tnp: TCP, numeric, process info
    # Ищем строки, где указан PID нашего контейнера
    conn_count=$(ss -tnp 2>/dev/null | grep -c "pid=${pid}" 2>/dev/null || echo "0")
  fi

  if (( conn_count > 0 )); then
    echo "active:${conn_count}"
  else
    echo "idle"
  fi
}

# ── check_port_listening — слушается ли ожидаемый порт ───────────────────────
# Берём порт из runtime.env и проверяем через port_in_use (util.sh).
# Возвращает:
#   "listening:<port>"     — порт активен
#   "not_listening:<port>" — порт не слушается
# ─────────────────────────────────────────────────────────────────────────────
check_port_listening() {
  local port
  port=$(runtime_get "PORT")
  port="${port:-$DEFAULT_PORT}"

  if port_in_use "$port"; then
    echo "listening:${port}"
  else
    echo "not_listening:${port}"
  fi
}

# ── check_uptime — время работы контейнера ───────────────────────────────────
# Извлекаем StartedAt из docker inspect, конвертируем в epoch,
# вычитаем из текущего времени.
# Формат вывода: "up:<N>h<M>m" или "not_running" / "unknown"
# ─────────────────────────────────────────────────────────────────────────────
check_uptime() {
  if ! container_running; then
    echo "not_running"
    return
  fi

  local started
  started=$(docker inspect --format '{{.State.StartedAt}}' "${CONTAINER_NAME}" 2>/dev/null || echo "")
  if [[ -z "$started" ]]; then
    echo "unknown"
    return
  fi

  # Конвертируем ISO-дату в unix epoch
  local started_epoch now uptime_seconds
  started_epoch=$(date -d "$started" +%s 2>/dev/null || date +%s)
  now=$(date +%s)
  uptime_seconds=$(( now - started_epoch ))

  if (( uptime_seconds < 0 )); then
    # Часовой пояс может дать отрицательное значение на пару секунд
    uptime_seconds=0
  fi

  local hours=$(( uptime_seconds / 3600 ))
  local minutes=$(( (uptime_seconds % 3600) / 60 ))
  echo "up:${hours}h${minutes}m"
}

# ─────────────────────────────────────────────────────────────────────────────
# monitor_summary — полная таблица мониторинга
# ─────────────────────────────────────────────────────────────────────────────
# Вызывает все эвристики и форматирует результат в виде таблицы.
# Для каждого признака выбираем подходящий эмодзи и описание.
# ─────────────────────────────────────────────────────────────────────────────
monitor_summary() {
  local process errors connections port uptime

  process=$(check_process)
  errors=$(check_errors_in_logs)
  connections=$(check_connections)
  port=$(check_port_listening)
  uptime=$(check_uptime)

  echo "┌─────────────────────────────────────────┐"
  echo "│  Эвристический мониторинг               │"
  echo "├─────────────────────────────────────────┤"

  # Процесс
  if [[ "$process" == "ok" ]]; then
    echo "│  Процесс:     ✅ запущен               │"
  else
    echo "│  Процесс:     ❌ не запущен            │"
  fi

  # Порт
  if [[ "$port" == listening:* ]]; then
    local p="${port#listening:}"
    echo "│  Порт:        ✅ слушает (${p})         │"
  else
    local p="${port#not_listening:}"
    echo "│  Порт:        ❌ не слушает (${p})      │"
  fi

  # Ошибки в логах
  if [[ "$errors" == "clean" ]]; then
    echo "│  Ошибки:      ✅ нет                   │"
  elif [[ "$errors" == errors_found:* ]]; then
    local cnt="${errors#errors_found:}"
    echo "│  Ошибки:      ⚠️  найдено (${cnt})      │"
  else
    echo "│  Ошибки:      ${errors}"
  fi

  # Сетевые соединения
  if [[ "$connections" == active:* ]]; then
    local cnt="${connections#active:}"
    echo "│  Соединения:  ✅ активно (${cnt})       │"
  elif [[ "$connections" == "idle" ]]; then
    echo "│  Соединения:  ⏸  нет подключений       │"
  else
    echo "│  Соединения:  ${connections}            │"
  fi

  # Uptime
  if [[ "$uptime" == up:* ]]; then
    local t="${uptime#up:}"
    printf "│  Uptime:      %-22s│\n" "$t"
  else
    printf "│  Uptime:      %-22s│\n" "$uptime"
  fi

  echo "└─────────────────────────────────────────┘"
}

# ─────────────────────────────────────────────────────────────────────────────
# monitor_health — быстрая проверка «здоровья»
# ─────────────────────────────────────────────────────────────────────────────
# Упрощённая версия monitor_summary для использования в doctor.
# Возвращает одно из двух:
#   "healthy"  — процесс запущен, порт слушается, ошибок в логах нет
#   "degraded" — хотя бы одна проверка провалилась
#
# Используется в `mtpx doctor` для итогового вердикта.
# ─────────────────────────────────────────────────────────────────────────────
monitor_health() {
  local process port errors

  process=$(check_process)
  port=$(check_port_listening)
  errors=$(check_errors_in_logs)

  local healthy=true

  # Контейнер должен работать
  if [[ "$process" != "ok" ]]; then
    healthy=false
  fi
  # Порт должен слушаться
  if [[ "$port" != listening:* ]]; then
    healthy=false
  fi
  # Ошибок в логах быть не должно
  if [[ "$errors" == errors_found:* ]]; then
    healthy=false
  fi

  if $healthy; then
    echo "healthy"
  else
    echo "degraded"
  fi
}
