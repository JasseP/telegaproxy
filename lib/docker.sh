#!/usr/bin/env bash
###############################################################################
# lib/docker.sh — управление Docker-контейнерами MTProxy (multi-proxy v2)
#
# Архитектура:
#   Каждый домен = отдельный контейнер.
#   Имя контейнера: mtproto-<normalized_domain>
#   Примеры: mtproto-ya-ru, mtproto-google-com, mtproto-cloudflare-com
#
# Это ЕДИНСТВЕННОЕ место в кодовой базе с вызовами Docker.
# Для замены backend (podman, bare-metal) — переписать только этот файл.
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
MT_PROXY_IMAGE="telegrammessenger/proxy"

# ─────────────────────────────────────────────────────────────────────────────
# Проверка состояния контейнера (по имени)
# ─────────────────────────────────────────────────────────────────────────────

# ── docker_container_exists — контейнер существует (даже stopped) ────────────
docker_container_exists() {
  local cname="$1"
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "$cname"
}

# ── docker_container_running — контейнер запущен прямо сейчас ────────────────
docker_container_running() {
  local cname="$1"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "$cname"
}

# ── docker_container_status — текстовый статус ───────────────────────────────
# Возвращает: running, stopped, none
# ─────────────────────────────────────────────────────────────────────────────
docker_container_status() {
  local cname="$1"
  if docker_container_running "$cname"; then
    echo "running"
  elif docker_container_exists "$cname"; then
    echo "stopped"
  else
    echo "none"
  fi
}

# ── docker_container_port — внешний порт контейнера ──────────────────────────
docker_container_port() {
  local cname="$1"
  if ! docker_container_running "$cname"; then
    echo "-"
    return
  fi
  local port_info
  port_info=$(docker port "$cname" 2>/dev/null || echo "")
  if [[ -n "$port_info" ]]; then
    # Формат: 443/tcp -> 0.0.0.0:4433 или 443/tcp -> :::4433
    echo "$port_info" | head -1 | grep -oE '[0-9]+$' || echo "-"
  else
    echo "-"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Операции с контейнерами
# ─────────────────────────────────────────────────────────────────────────────

# ── docker_stop_container — остановить ──────────────────────────────────────
docker_stop_container() {
  local cname="$1"
  if docker_container_running "$cname"; then
    docker stop "$cname" >/dev/null 2>&1 || true
  fi
}

# ── docker_remove_container — остановить и удалить ──────────────────────────
docker_remove_container() {
  local cname="$1"
  docker_stop_container "$cname"
  if docker_container_exists "$cname"; then
    docker rm "$cname" >/dev/null 2>&1 || true
  fi
}

# ── docker_restart_container — перезапустить ────────────────────────────────
docker_restart_container() {
  local cname="$1"
  if ! docker_container_running "$cname"; then
    log_error "Контейнер ${cname} не запущен"
    return 1
  fi
  log_step "Перезапуск ${cname}..."
  docker restart "$cname" >/dev/null 2>&1
  log_ok
}

# ── docker_container_logs ───────────────────────────────────────────────────
docker_container_logs() {
  local cname="$1"
  local lines="${2:-20}"
  if ! docker_container_exists "$cname"; then
    log_error "Контейнер ${cname} не найден"
    return 1
  fi
  docker logs --tail "$lines" "$cname" 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# docker_start_for_domain — запустить контейнер для домена
# ─────────────────────────────────────────────────────────────────────────────
# docker_start_for_domain <domain> <container_name> <secret> [port]
#
# Запускает контейнер с:
#   --name <container_name>
#   --restart unless-stopped
#   -p <port>:443
#   -e SECRET=<secret>
#
# Если port не указан — выбирает свободный из стандартного диапазона.
# ─────────────────────────────────────────────────────────────────────────────
docker_start_for_domain() {
  local domain="$1"
  local cname="$2"
  local secret="$3"
  local port="${4:-}"

  # Если порт не указан — ищем свободный
  if [[ -z "$port" ]]; then
    port=$(find_free_port 443 8443 8444 8445 8446 8447 8448 8449 8450) || {
      log_error "Нет свободных портов для '${domain}'"
      return 1
    }
  fi

  # Проверяем, не занят ли контейнер уже
  if docker_container_running "$cname"; then
    log_warn "Контейнер ${cname} уже запущен"
    return 0
  fi

  # Если контейнер существует (stopped) — удаляем
  if docker_container_exists "$cname"; then
    docker rm "$cname" >/dev/null 2>&1 || true
  fi

  log_step "Запуск ${cname}..."
  echo "  Образ:   ${MT_PROXY_IMAGE}"
  echo "  Домен:   ${domain}"
  echo "  Порт:    ${port}:443"
  echo "  Secret:  $(mask_secret "$secret")"

  if docker run -d \
    --name "$cname" \
    --restart unless-stopped \
    -p "${port}:443" \
    -e SECRET="${secret}" \
    "${MT_PROXY_IMAGE}" >/dev/null 2>&1; then

    # Ждём запуска
    sleep 2

    if docker_container_running "$cname"; then
      # Обновляем runtime (порт первого домена — для обратной совместимости)
      runtime_set "PORT" "$port"
      runtime_set "LAST_APPLY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      log_info "Контейнер ${cname} запущен"
      return 0
    else
      log_error "Контейнер ${cname} не запустился"
      docker logs "$cname" 2>&1 || true
      return 1
    fi
  else
    log_error "Ошибка при запуске контейнера ${cname}"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# apply_all — применить конфигурацию ко всем доменам
# ─────────────────────────────────────────────────────────────────────────────
# Для каждого домена в domains.txt:
#   1. Находит активный секрет
#   2. Запускает (или перезапускает) контейнер
#
# Если домен уже запущен — пропускает (без пересоздания).
# Если контейнер stopped — пересоздаёт.
# Если контейнера нет — создаёт.
# ─────────────────────────────────────────────────────────────────────────────
apply_all() {
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    log_error "Нет доменов. Добавьте: mtpx domain add <domain>"
    return 1
  fi

  local total=0 started=0 failed=0

  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue  # заголовок

    total=$(( total + 1 ))
    local cname secret
    cname=$(container_name_for_domain "$domain")
    secret=$(secrets_active_for_domain "$domain")

    if [[ -z "$secret" ]]; then
      log_warn "Нет секрета для '${domain}' — пропускаю"
      continue
    fi

    # Проверяем текущий статус
    local cstatus
    cstatus=$(docker_container_status "$cname")

    case "$cstatus" in
      running)
        log_info "${domain} (${cname}): уже запущен ✓"
        started=$(( started + 1 ))
        ;;
      stopped)
        log_step "${domain} (${cname}): пересоздаю..."
        docker_remove_container "$cname"
        if docker_start_for_domain "$domain" "$cname" "$secret"; then
          started=$(( started + 1 ))
        else
          failed=$(( failed + 1 ))
        fi
        ;;
      none)
        log_step "${domain} (${cname}): запускаю..."
        if docker_start_for_domain "$domain" "$cname" "$secret"; then
          started=$(( started + 1 ))
        else
          failed=$(( failed + 1 ))
        fi
        ;;
    esac
  done < "${DOMAINS_FILE}"

  echo ""
  if (( total == 0 )); then
    log_error "Нет доменов в списке"
    return 1
  elif (( failed == 0 )); then
    log_info "Запущено: ${started}/${total}"
  else
    log_warn "Запущено: ${started}/${total}, ошибок: ${failed}"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# apply_single — применить для одного домена
# ─────────────────────────────────────────────────────────────────────────────
apply_single() {
  local domain="$1"
  local cname secret
  cname=$(container_name_for_domain "$domain")
  secret=$(secrets_active_for_domain "$domain")

  if [[ -z "$secret" ]]; then
    log_error "Нет секрета для домена '${domain}'"
    return 1
  fi

  docker_remove_container "$cname"
  docker_start_for_domain "$domain" "$cname" "$secret"
}

# ─────────────────────────────────────────────────────────────────────────────
# Операции со ВСЕМИ контейнерами (для status/doctor)
# ─────────────────────────────────────────────────────────────────────────────

# Считаем запущенные mtproto-контейнеры
count_running_proxies() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^mtproto-' || echo "0"
}

# Считаем все mtproto-контейнеры
count_all_proxies() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c '^mtproto-' || echo "0"
}

# ─────────────────────────────────────────────────────────────────────────────
# stop_all / restart_all — операции со всеми прокси
# ─────────────────────────────────────────────────────────────────────────────
stop_all() {
  local count=0
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue

    local cname
    cname=$(container_name_for_domain "$domain")
    if docker_container_running "$cname"; then
      docker_stop_container "$cname"
      count=$(( count + 1 ))
    fi
  done < "${DOMAINS_FILE}"
  log_info "Остановлено контейнеров: ${count}"
}

restart_all() {
  local count=0
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue

    local cname
    cname=$(container_name_for_domain "$domain")
    if docker_container_running "$cname"; then
      docker_restart_container "$cname"
      count=$(( count + 1 ))
    fi
  done < "${DOMAINS_FILE}"
  log_info "Перезапущено контейнеров: ${count}"
}
