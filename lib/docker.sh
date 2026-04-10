#!/usr/bin/env bash
###############################################################################
# lib/docker.sh — управление Docker-контейнерами MTProxy (v3: multi-user)
#
# Образ: alexbers/mtprotoproxy — Python-реализация MTProxy с поддержкой
# нескольких секретов в одном контейнере.
#
# Конфиг монтируется через volume:
#   -v config/proxy-<domain>.py:/etc/mtproxy/proxy.conf:ro
#
# Каждый домен = отдельный контейнер.
# Каждый пользователь = отдельный секрет в конфиге контейнера.
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${MTPX_ROOT}/lib/config.sh"
# shellcheck source=lib/secret.sh
source "${MTPX_ROOT}/lib/secret.sh"
# shellcheck source=lib/config_proxy.sh
source "${MTPX_ROOT}/lib/config_proxy.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Образ прокси
# ─────────────────────────────────────────────────────────────────────────────
# alexbers/mtprotoproxy — поддерживает несколько секретов, Fake TLS
# Альтернатива: можно заменить на другой форк, изменив только эту переменную
# и логику запуска.
# ─────────────────────────────────────────────────────────────────────────────
MT_PROXY_IMAGE="alexbers/mtprotoproxy"

# ─────────────────────────────────────────────────────────────────────────────
# Проверка состояния контейнера (по имени)
# ─────────────────────────────────────────────────────────────────────────────

docker_container_exists() {
  local cname="$1"
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "$cname"
}

docker_container_running() {
  local cname="$1"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "$cname"
}

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

docker_container_port() {
  local cname="$1"
  if ! docker_container_running "$cname"; then
    echo "-"
    return
  fi
  local port_info
  port_info=$(docker port "$cname" 2>/dev/null || echo "")
  if [[ -n "$port_info" ]]; then
    echo "$port_info" | head -1 | grep -oE '[0-9]+$' || echo "-"
  else
    echo "-"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Операции с контейнерами
# ─────────────────────────────────────────────────────────────────────────────

docker_stop_container() {
  local cname="$1"
  if docker_container_running "$cname"; then
    docker stop "$cname" >/dev/null 2>&1 || true
  fi
}

docker_remove_container() {
  local cname="$1"
  docker_stop_container "$cname"
  if docker_container_exists "$cname"; then
    docker rm "$cname" >/dev/null 2>&1 || true
  fi
}

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
# docker_start_for_domain <domain> <container_name> [port]
#
# Монтирует конфиг: config/proxy-<domain>.py → /etc/mtproxy/proxy.conf
# alexbers/mtprotoproxy читает конфиг и запускается со всеми секретами.
# ─────────────────────────────────────────────────────────────────────────────
docker_start_for_domain() {
  local domain="$1"
  local cname="$2"
  local port="${3:-}"

  # Нормализуем имя конфига
  local norm
  norm=$(normalize_domain "$domain")
  local config_file="${CONFIG_DIR}/proxy-${norm}.py"

  # Генерируем конфиг (если секреты есть — хорошо, если нет — с пустым списком)
  generate_proxy_config "$domain" 2>/dev/null || true

  # Если конфига всё равно нет — не запускаем
  if [[ ! -f "$config_file" ]]; then
    log_error "Конфиг не найден и не создан: ${config_file}"
    log_warn "Добавьте пользователя и секреты: mtpx user add <name>"
    return 1
  fi

  # Определяем порт
  if [[ -z "$port" ]]; then
    port=$(find_free_port 443 8443 8444 8445 8446 8447 8448 8449 8450) || {
      log_error "Нет свободных портов для '${domain}'"
      return 1
    }
  fi

  # Нормализуем имя конфига
  local norm
  norm=$(normalize_domain "$domain")
  local config_file="${CONFIG_DIR}/proxy-${norm}.py"

  if [[ ! -f "$config_file" ]]; then
    log_error "Конфиг не найден: ${config_file}"
    return 1
  fi

  # Удаляем старый контейнер, если есть
  if docker_container_exists "$cname"; then
    docker_remove_container "$cname"
  fi

  log_step "Запуск ${cname}..."
  echo "  Образ:   ${MT_PROXY_IMAGE}"
  echo "  Домен:   ${domain}"
  echo "  Порт:    ${port}"
  echo "  Конфиг:  proxy-${norm}.py"

  if docker run -d \
    --name "$cname" \
    --restart unless-stopped \
    -p "${port}:443" \
    -v "${config_file}:/etc/mtproxy/proxy.conf:ro" \
    "${MT_PROXY_IMAGE}" >/dev/null 2>&1; then

    sleep 2

    if docker_container_running "$cname"; then
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
# docker_config_sync_all — перегенерировать конфиги всех доменов и перезапустить
# ─────────────────────────────────────────────────────────────────────────────
# Вызывается при:
#   • Добавлении/удалении пользователя
#   • Добавлении/удалении домена
#   • Ротации секретов
# ─────────────────────────────────────────────────────────────────────────────
docker_config_sync_all() {
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    return 0
  fi

  local sync_count=0
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue

    # Перегенерируем конфиг
    generate_proxy_config "$domain" 2>/dev/null || continue

    # Перезапускаем контейнер, если он запущен
    local cname
    cname=$(container_name_for_domain "$domain")
    if docker_container_running "$cname"; then
      docker_restart_container "$cname"
      sync_count=$(( sync_count + 1 ))
    fi
  done < "${DOMAINS_FILE}"

  if (( sync_count > 0 )); then
    log_info "Перезапущено контейнеров: ${sync_count}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# apply_all — запустить все домены
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
    [[ "$domain" == "domain" ]] && continue

    total=$(( total + 1 ))
    local cname
    cname=$(container_name_for_domain "$domain")
    local cstatus
    cstatus=$(docker_container_status "$cname")

    case "$cstatus" in
      running)
        # Перегенерируем конфиг (могли добавиться пользователи)
        generate_proxy_config "$domain" 2>/dev/null || true
        docker_restart_container "$cname"
        started=$(( started + 1 ))
        ;;
      stopped|none)
        if docker_start_for_domain "$domain" "$cname"; then
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
  local cname
  cname=$(container_name_for_domain "$domain")
  docker_remove_container "$cname"
  docker_start_for_domain "$domain" "$cname"
}

# ─────────────────────────────────────────────────────────────────────────────
# Операции со ВСЕМИ контейнерами
# ─────────────────────────────────────────────────────────────────────────────

count_running_proxies() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^mtproto-' || echo "0"
}

count_all_proxies() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c '^mtproto-' || echo "0"
}

stop_all() {
  local count=0
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    return 0
  fi
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
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    return 0
  fi
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
