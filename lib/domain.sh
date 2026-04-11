#!/usr/bin/env bash
###############################################################################
# lib/domain.sh — управление доменами (v4: один контейнер = один пользователь)
#
# Каждый домен + пользователь = отдельный контейнер.
# При добавлении домена — создаются контейнеры для всех пользователей.
# При удалении домена — удаляются все контейнеры для этого домена.
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

# ─────────────────────────────────────────────────────────────────────────────
# domain_add — создать домен + контейнеры для всех пользователей
# ─────────────────────────────────────────────────────────────────────────────
domain_add() {
  local domain="$1"
  local port_start="${2:-443}"

  validate_domain "$domain"

  local cname
  cname=$(container_name_for "$domain" "_")  # проверяем по префиксу
  # Проверяем, есть ли уже контейнеры для этого домена
  local norm
  norm=$(normalize_domain "$domain")
  local existing
  existing=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^mtproto-${norm}-" || echo "")
  if [[ -n "$existing" ]]; then
    log_warn "Домен '${domain}' уже существует"
    return 0
  fi

  log_step "Создание домена '${domain}'..."

  # Получаем список пользователей
  local users=""
  if [[ -f "${USERS_FILE}" ]]; then
    users=$(active_users 2>/dev/null || echo "")
  fi

  if [[ -n "$users" ]]; then
    local user_count=0
    local current_port="$port_start"
    while IFS=',' read -r uid username created status comment; do
      [[ -z "$uid" ]] && continue

      # Создаём секрет
      secret_add_for "$domain" "$username" "auto-created by domain add"

      # Получаем секрет
      local secret
      secret=$(secret_for_user_domain "$username" "$domain")
      if [[ -n "$secret" ]]; then
        # Находим свободный порт
        local port
        port=$(find_free_port "$current_port" 8443 8444 8445 8446 8447 8448 8449 8450) || {
          log_error "Нет свободных портов"
          return 1
        }
        current_port=$(( port + 1 ))

        docker_start_container "$domain" "$username" "$secret" "$port"
        user_count=$(( user_count + 1 ))
      fi
    done <<< "$users"
    log_info "Создано контейнеров: ${user_count}"
  else
    log_warn "Нет пользователей. Добавьте: mtpx user add <name>"
  fi

  # Добавляем домен в список
  add_domain_to_list "$domain"

  echo ""
  echo "  Все ссылки: mtpx user show <username>"
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_remove — удалить домен + все контейнеры + секреты
# ─────────────────────────────────────────────────────────────────────────────
domain_remove() {
  local domain="$1"

  validate_domain "$domain"

  log_step "Удаление домена '${domain}'..."

  # Удаляем все контейнеры для домена
  docker_remove_all_for_domain "$domain"

  # Удаляем секреты
  secrets_remove_for_domain "$domain"

  # Удаляем из списка
  remove_domain_from_list "$domain"

  log_info "Домен '${domain}' полностью удалён"
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_list — список всех доменов
# ─────────────────────────────────────────────────────────────────────────────
domain_list() {
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    echo "  Нет доменов. Добавьте: mtpx domain add <domain>"
    return 0
  fi

  local domain_count
  domain_count=$(tail -n +2 "${DOMAINS_FILE}" | grep -c '.' 2>/dev/null || echo "0")

  if (( domain_count == 0 )); then
    echo "  Нет доменов. Добавьте: mtpx domain add <domain>"
    return 0
  fi

  echo "┌──────────────────┬─────────┬───────────────┐"
  echo "│ Домен            │ Пользов.│ Контейнеры    │"
  echo "├──────────────────┼─────────┼───────────────┤"

  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue

    # Считаем контейнеры для домена
    local norm
    norm=$(normalize_domain "$domain")
    local running total
    running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep "^mtproto-${norm}-" | wc -l || echo "0")
    total=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^mtproto-${norm}-" | wc -l || echo "0")

    # Считаем пользователей
    local user_cnt
    user_cnt=$(secrets_count_for_domain "$domain" 2>/dev/null || echo "0")

    local icon
    if (( running == 0 )); then
      icon="🔴"
    elif (( running == total )); then
      icon="🟢"
    else
      icon="🟡"
    fi

    printf "│ %-16s │ %-7s │ %s %d/%d          │\n" \
      "$domain" "$user_cnt" "$icon" "$running" "$total"
  done < "${DOMAINS_FILE}"

  echo "└──────────────────┴─────────┴───────────────┘"
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_links_all — все ссылки для всех доменов
# ─────────────────────────────────────────────────────────────────────────────
domain_links_all() {
  local server="${1:-}"
  if [[ -z "$server" ]]; then
    server=$(get_server_ip)
  fi

  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    log_error "Нет доменов"
    return 1
  fi

  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue

    # Для каждого пользователя на этом домене
    secrets_for_domain "$domain" 2>/dev/null | while IFS=',' read -r secret username; do
      [[ -z "$secret" ]] && continue
      local cname port
      cname=$(container_name_for "$domain" "$username")
      port=$(docker_container_port "$cname" 2>/dev/null || echo "-")
      echo "  ${domain} (${username}):"
      printf '    tg://proxy?server=%s&port=%s&secret=%s\n' "$server" "$port" "$secret"
      echo ""
    done
  done < "${DOMAINS_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_restart / domain_stop / domain_start / domain_logs
# ─────────────────────────────────────────────────────────────────────────────
domain_restart() {
  local domain="$1"
  local norm
  norm=$(normalize_domain "$domain")
  docker ps --format '{{.Names}}' 2>/dev/null | grep "^mtproto-${norm}-" | while IFS= read -r cname; do
    docker_restart_container "$cname"
  done
}

domain_stop() {
  local domain="$1"
  local norm
  norm=$(normalize_domain "$domain")
  docker ps --format '{{.Names}}' 2>/dev/null | grep "^mtproto-${norm}-" | while IFS= read -r cname; do
    docker_stop_container "$cname"
    log_info "Остановлен ${cname}"
  done
}

domain_start() {
  local domain="$1"
  local norm
  norm=$(normalize_domain "$domain")
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^mtproto-${norm}-" | while IFS= read -r cname; do
    # Извлекаем username из имени контейнера
    local username="${cname#mtproto-${norm}-}"
    local secret
    secret=$(secret_for_user_domain "$username" "$domain")
    if [[ -n "$secret" ]]; then
      local port
      port=$(find_free_port 443 8443 8444 8445 8446 8447 8448 8449 8450) || return 1
      docker_start_container "$domain" "$username" "$secret" "$port"
    fi
  done
}

domain_logs() {
  local domain="$1"
  local lines="${2:-20}"
  local norm
  norm=$(normalize_domain "$domain")
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^mtproto-${norm}-" | while IFS= read -r cname; do
    echo "=== ${cname} ==="
    docker_container_logs "$cname" "$lines"
    echo ""
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_inspect — информация о всех контейнерах домена
# ─────────────────────────────────────────────────────────────────────────────
domain_inspect() {
  local domain="$1"
  local norm
  norm=$(normalize_domain "$domain")

  local containers
  containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^mtproto-${norm}-" || echo "")

  if [[ -z "$containers" ]]; then
    log_warn "Нет контейнеров для домена '${domain}'"
    return 0
  fi

  echo "$containers" | while IFS= read -r cname; do
    local cstatus port
    cstatus=$(docker_container_status "$cname")
    port=$(docker_container_port "$cname" 2>/dev/null || echo "-")
    echo "  ${cname}: status=${cstatus} port=${port}"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Хелперы для списка доменов
# ─────────────────────────────────────────────────────────────────────────────
domains_init() {
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    atomic_write "${DOMAINS_FILE}" "domain"
    log_info "Создан ${DOMAINS_FILE}"
  fi
}

domain_list_raw() {
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(printf '%s' "$line" | tr -d '\r')
    [[ -z "$line" ]] && continue
    [[ "$line" == "domain" ]] && continue
    printf '%s\n' "$line"
  done < "${DOMAINS_FILE}"
}

add_domain_to_list() {
  local domain="$1"
  if [[ -f "${DOMAINS_FILE}" ]] && grep -qxF "$domain" "${DOMAINS_FILE}" 2>/dev/null; then
    return 0
  fi
  local tmp
  tmp="$(mktemp "${DOMAINS_FILE}.tmp.XXXXXX")"
  if [[ -f "${DOMAINS_FILE}" ]]; then
    cat "${DOMAINS_FILE}" > "$tmp"
  fi
  printf '%s\n' "$domain" >> "$tmp"
  mv -f "$tmp" "${DOMAINS_FILE}"
}

remove_domain_from_list() {
  local domain="$1"
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    return 0
  fi
  local tmp
  tmp="$(mktemp "${DOMAINS_FILE}.tmp.XXXXXX")"
  grep -vxF "$domain" "${DOMAINS_FILE}" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "${DOMAINS_FILE}"
}
