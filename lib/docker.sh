#!/usr/bin/env bash
###############################################################################
# lib/docker.sh — управление Docker-контейнером MTProxy
#
# Этот модуль — ЕДИНСТВЕННОЕ место в кодовой базе, где есть прямые вызовы
# Docker. Архитектурное следствие: если в будущем потребуется заменить
# backend (например, на systemd-nspawn, podman, или bare-metal), нужно
# будет переписать только этот файл. Остальной код (mtpx, secret.sh, и т.д.)
# работает с абстракциями: container_start, container_stop, apply.
#
# Используемый образ: telegrammessenger/proxy (официальный от Telegram)
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${MTPX_ROOT}/lib/config.sh"
# shellcheck source=lib/secret.sh
source "${MTPX_ROOT}/lib/secret.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Образ прокси
# ─────────────────────────────────────────────────────────────────────────────
# telegrammessenger/proxy — официальный Docker-образ от команды Telegram.
# Принимает переменную окружения SECRET и слушает порт 443 внутри контейнера.
# Если нужно использовать другой образ (fork, custom build) — меняем здесь.
# ─────────────────────────────────────────────────────────────────────────────
MT_PROXY_IMAGE="telegrammessenger/proxy"

# ─────────────────────────────────────────────────────────────────────────────
# Проверка состояния контейнера
# ─────────────────────────────────────────────────────────────────────────────

# ── container_exists — контейнер существует (даже остановленный) ─────────────
# docker ps -a — все контейнеры (включая stopped).
# --format '{{.Names}}' — выводим только имена.
# grep -qxF — точное совпадение имени (не substring).
# ─────────────────────────────────────────────────────────────────────────────
container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "${CONTAINER_NAME}"
}

# ── container_running — контейнер запущен прямо сейчас ───────────────────────
# docker ps (без -a) — только running контейнеры.
# ─────────────────────────────────────────────────────────────────────────────
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "${CONTAINER_NAME}"
}

# ─────────────────────────────────────────────────────────────────────────────
# container_stop — остановить и удалить контейнер
# ─────────────────────────────────────────────────────────────────────────────
# Двухшаговый процесс:
#   1. docker stop — корректная остановка (SIGTERM, через 10с SIGKILL)
#   2. docker rm   — удаление контейнера (освобождение имени)
#
# Каждый шаг проверяет, существует ли контейнер, чтобы избежать ошибок.
# > /dev/null 2>&1 — подавляем вывод, т.к. статус показываем сами.
# ─────────────────────────────────────────────────────────────────────────────
container_stop() {
  if container_running; then
    log_step "Остановка контейнера ${CONTAINER_NAME}..."
    docker stop "${CONTAINER_NAME}" >/dev/null 2>&1
    log_ok
  fi
  if container_exists; then
    log_step "Удаление контейнера ${CONTAINER_NAME}..."
    docker rm "${CONTAINER_NAME}" >/dev/null 2>&1
    log_ok
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# container_start — запустить новый контейнер
# ─────────────────────────────────────────────────────────────────────────────
# container_start [port] [secret]
#
# port   — внешний порт для маппинга (внутри контейнера всегда 443)
# secret — MTProxy-секрет (hex-строка)
#
# Логика:
#   1. Если secret не передан — берём первый активный из secrets.csv
#   2. Проверяем, свободен ли порт; если занят — ищем альтернативу
#   3. docker run -d (detached) с:
#      --restart unless-stopped  — автозапуск после reboot
#      -p <port>:443             — маппинг порта
#      -e SECRET=<secret>        — передача секрета
#   4. Ждём 2 секунды на запуск
#   5. Проверяем, что контейнер действительно работает
#   6. Обновляем runtime.env (порт, время, маскированный секрет)
# ─────────────────────────────────────────────────────────────────────────────
container_start() {
  local port="${1:-$DEFAULT_PORT}"
  local secret="${2:-}"

  # Если секрет не передан — берём первый активный
  if [[ -z "$secret" ]]; then
    secret=$(secret_get_active)
    if [[ -z "$secret" ]]; then
      log_error "Нет активных секретов. Добавьте: mtpx secret add"
      return 1
    fi
  fi

  # Проверяем, свободен ли порт
  local actual_port="$port"
  if port_in_use "$port"; then
    log_warn "Порт ${port} занят, ищем альтернативу..."
    actual_port=$(find_free_port 8443 8444 8445 8446 8447) || {
      log_error "Нет свободных портов"
      return 1
    }
    log_info "Используем порт: ${actual_port}"
  fi

  # Запускаем контейнер
  log_step "Запуск контейнера ${CONTAINER_NAME}..."
  echo "  Образ: ${MT_PROXY_IMAGE}"
  echo "  Порт:  ${actual_port}:443"
  echo "  Secret: $(mask_secret "$secret")"

  docker run -d \
    --name "${CONTAINER_NAME}" \
    --restart unless-stopped \
    -p "${actual_port}:443" \
    -e SECRET="${secret}" \
    "${MT_PROXY_IMAGE}" >/dev/null 2>&1

  # Ждём, пока контейнер поднимется
  sleep 2

  # Проверяем результат
  if container_running; then
    # Обновляем runtime-параметры
    runtime_set "PORT" "$actual_port"
    runtime_set "LAST_APPLY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    runtime_set "SECRET" "$(mask_secret "$secret")"

    log_info "Контейнер запущен"
    return 0
  else
    # Контейнер не запустился — показываем логи для отладки
    log_error "Контейнер не запустился"
    docker logs "${CONTAINER_NAME}" 2>&1 || true
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# apply — полная пересборка: остановить старый → запустить новый
# ─────────────────────────────────────────────────────────────────────────────
# apply [port]
#
# Главная команда для применения конфигурации. Последовательность:
#   1. Определяем порт (из аргумента или runtime.env)
#   2. Проверяем, что есть хотя бы один активный секрет
#   3. Останавливаем и удаляем старый контейнер
#   4. Запускаем новый с текущим секретом
#   5. Выводим сводку (сервер, порт, домен)
#
# Это точка, где все модули сходятся: secrets → docker → runtime → config.
# ─────────────────────────────────────────────────────────────────────────────
apply() {
  local port="${1:-}"
  if [[ -z "$port" ]]; then
    port=$(runtime_get "PORT")
    port="${port:-$DEFAULT_PORT}"
  fi

  log_step "Применение конфигурации..."

  # Проверяем, что есть секреты
  local active_count
  active_count=$(secret_count 2>/dev/null || echo "0")
  if (( active_count == 0 )); then
    log_error "Нет секретов. Выполните: mtpx secret add"
    return 1
  fi

  # Берём первый активный секрет
  local secret
  secret=$(secret_get_active)
  if [[ -z "$secret" ]]; then
    log_error "Не удалось получить активный секрет"
    return 1
  fi

  # Останавливаем старый контейнер
  container_stop

  # Запускаем новый
  if container_start "$port" "$secret"; then
    log_info "Конфигурация применена"
    echo ""
    echo "┌─────────────────────────────────────────┐"
    echo "│  Прокси запущен                         │"
    echo "├─────────────────────────────────────────┤"
    local ip
    ip=$(get_server_ip)
    echo "│  Сервер:  ${ip}"
    echo "│  Порт:    ${port}"
    echo "│  Домен:   $(domain_current)"
    echo "└─────────────────────────────────────────┘"
    echo ""
    echo "  Ссылка: mtpx secret link"
    return 0
  else
    log_error "Не удалось запустить контейнер"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# container_logs — вывод логов контейнера
# ─────────────────────────────────────────────────────────────────────────────
# container_logs [n] — последние n строк (по умолчанию 20).
# 2>&1 — stderr тоже в stdout (docker пишет логи в stderr).
# ─────────────────────────────────────────────────────────────────────────────
container_logs() {
  local lines="${1:-20}"
  if ! container_exists; then
    log_error "Контейнер ${CONTAINER_NAME} не найден"
    return 1
  fi
  docker logs --tail "$lines" "${CONTAINER_NAME}" 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# container_status — текстовый статус контейнера
# ─────────────────────────────────────────────────────────────────────────────
# Возвращает одно из трёх значений:
#   running — контейнер запущен
#   stopped — контейнер существует, но остановлен
#   none    — контейнер не создан
# ─────────────────────────────────────────────────────────────────────────────
container_status() {
  if container_running; then
    echo "running"
  elif container_exists; then
    echo "stopped"
  else
    echo "none"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# container_ports — показать маппинг портов
# ─────────────────────────────────────────────────────────────────────────────
# docker port показывает: 443/tcp -> 0.0.0.0:<port>
# ─────────────────────────────────────────────────────────────────────────────
container_ports() {
  if ! container_running; then
    return 1
  fi
  docker port "${CONTAINER_NAME}" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# container_restart — перезапустить контейнер
# ─────────────────────────────────────────────────────────────────────────────
# docker restart = stop + start. Быстрее, чем container_stop + container_start,
# т.к. не пересоздаёт контейнер (сохраняет те же настройки).
# Полезно, если прокси «завис» или нужно обновить секрет через exec.
# ─────────────────────────────────────────────────────────────────────────────
container_restart() {
  if ! container_running; then
    log_error "Контейнер не запущен"
    return 1
  fi
  log_step "Перезапуск ${CONTAINER_NAME}..."
  docker restart "${CONTAINER_NAME}" >/dev/null 2>&1
  log_ok
}
