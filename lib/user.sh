#!/usr/bin/env bash
###############################################################################
# lib/user.sh — управление пользователями (v4: один контейнер = один пользователь)
#
# При добавлении пользователя — создаются контейнеры для всех доменов.
# При удалении — удаляются все контейнеры пользователя.
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
# Инициализация
# ─────────────────────────────────────────────────────────────────────────────
users_init() {
  if [[ ! -f "${USERS_FILE}" ]]; then
    atomic_write "${USERS_FILE}" "id,username,created_at,status,comment"
    log_info "Создан ${USERS_FILE}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Утилиты
# ─────────────────────────────────────────────────────────────────────────────
_user_id() {
  printf 'u_%s' "$(date +%s)_$$"
}

_users_check() {
  if [[ ! -f "${USERS_FILE}" ]]; then
    log_error "Файл пользователей не найден. Выполните: mtpx init"
    return 1
  fi
}

user_count() {
  _users_check || return 1
  tail -n +2 "${USERS_FILE}" | wc -l
}

active_users() {
  _users_check || return 1
  tail -n +2 "${USERS_FILE}" | awk -F',' '$4=="active"'
}

user_find() {
  _users_check || return 1
  local username="$1"
  tail -n +2 "${USERS_FILE}" | awk -F',' -v u="$username" '$2==u'
}

user_get_id() {
  local line
  line=$(user_find "$1")
  if [[ -n "$line" ]]; then
    echo "$line" | cut -d',' -f1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# user_add — создать пользователя + контейнеры для всех доменов
# ─────────────────────────────────────────────────────────────────────────────
user_add() {
  local username="$1"
  local comment="${2:-}"

  if [[ -z "$username" ]]; then
    log_error "Укажите имя: mtpx user add <username>"
    return 1
  fi

  if [[ -n "$(user_find "$username")" ]]; then
    log_warn "Пользователь '${username}' уже существует"
    return 0
  fi

  # Создаём запись пользователя
  local uid created_at
  uid=$(_user_id)
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local tmp
  tmp="$(mktemp "${USERS_FILE}.tmp.XXXXXX")"
  cat "${USERS_FILE}" > "$tmp"
  printf '%s,%s,%s,%s,%s\n' "$uid" "$username" "$created_at" "active" "$comment" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${USERS_FILE}"

  log_info "Пользователь '${username}' создан (id: ${uid})"

  # Создаём секреты и контейнеры для всех доменов
  if [[ -f "${DOMAINS_FILE}" ]]; then
    local domain_count=0
    local current_port=443
    while IFS= read -r domain || [[ -n "$domain" ]]; do
      domain=$(printf '%s' "$domain" | tr -d '\r')
      [[ -z "$domain" ]] && continue
      [[ "$domain" == "domain" ]] && continue

      # Создаём секрет
      secret_add_for "$domain" "$username" "auto-created by user add"

      # Получаем секрет
      local secret
      secret=$(secret_for_user_domain "$username" "$domain")
      if [[ -n "$secret" ]]; then
        local port
        port=$(find_free_port "$current_port" 8443 8444 8445 8446 8447 8448 8449 8450) || {
          log_error "Нет свободных портов"
          return 1
        }
        current_port=$(( port + 1 ))

        docker_start_container "$domain" "$username" "$secret" "$port"
        domain_count=$(( domain_count + 1 ))
      fi
    done < "${DOMAINS_FILE}"

    if (( domain_count > 0 )); then
      log_info "Создано контейнеров: ${domain_count}"
    else
      log_warn "Нет доменов. Секреты будут созданы при добавлении домена."
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# user_remove — удалить пользователя + все контейнеры + секреты
# ─────────────────────────────────────────────────────────────────────────────
user_remove() {
  local username="$1"

  local line
  line=$(user_find "$username")
  if [[ -z "$line" ]]; then
    log_error "Пользователь '${username}' не найден"
    return 1
  fi

  local uid
  uid=$(echo "$line" | cut -d',' -f1)

  # Удаляем все контейнеры пользователя
  docker_remove_all_for_user "$username"

  # Удаляем секреты
  secrets_remove_for_user "$username"

  # Меняем статус
  _user_set_field "$uid" "status" "revoked"

  log_info "Пользователь '${username}' удалён"
}

# ─────────────────────────────────────────────────────────────────────────────
# user_list
# ─────────────────────────────────────────────────────────────────────────────
user_list() {
  _users_check || return 1

  echo "┌──────┬──────────────────┬────────────┬──────────┬──────────┐"
  echo "│ ID   │ Username         │ Created    │ Status   │ Domains  │"
  echo "├──────┼──────────────────┼────────────┼──────────┼──────────┤"

  local first=true
  while IFS=',' read -r id username created status comment; do
    if $first; then first=false; continue; fi
    local domains
    domains=$(user_domain_count "$username" 2>/dev/null || echo "0")
    printf "│ %-4s │ %-16s │ %-10s │ %-8s │ %-8s │\n" \
      "$id" "$username" "${created:0:10}" "$status" "$domains"
  done < "${USERS_FILE}"

  echo "└──────┴──────────────────┴────────────┴──────────┴──────────┘"
}

# ─────────────────────────────────────────────────────────────────────────────
# user_show — карточка пользователя со всеми ссылками
# ─────────────────────────────────────────────────────────────────────────────
user_show() {
  local username="$1"
  local server_override="${2:-}"

  local line
  line=$(user_find "$username")
  if [[ -z "$line" ]]; then
    log_error "Пользователь '${username}' не найден"
    return 1
  fi

  IFS=',' read -r uid username created status comment <<< "$line"

  echo ""
  echo "╔═════════════════════════════════════════════╗"
  echo "║  Пользователь: ${username}"
  echo "╠═════════════════════════════════════════════╣"
  echo "║  ID:       ${uid}"
  echo "║  Created:  ${created}"
  echo "║  Status:   ${status}"
  echo "║  Comment:  ${comment:--}"
  echo "╚═════════════════════════════════════════════╝"

  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    echo ""
    echo "  Нет доменов"
    return 0
  fi

  local server
  if [[ -n "$server_override" ]]; then
    server="$server_override"
  else
    server=$(get_server_ip)
  fi

  local found=0
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue

    local secret
    secret=$(secret_for_user_domain "$username" "$domain" 2>/dev/null || echo "")
    [[ -z "$secret" ]] && continue

    local cname port
    cname=$(container_name_for "$domain" "$username")
    port=$(docker_container_port "$cname" 2>/dev/null || echo "$DEFAULT_PORT")

    found=$(( found + 1 ))

    echo ""
    echo "┌─────────────────────────────────────────────┐"
    echo "│  🌐 Домен: ${domain}"
    echo "├─────────────────────────────────────────────┤"
    echo "│  Ссылка для подключения:"
    echo "│  tg://proxy?server=${server}&port=${port}&secret=${secret}"
    echo "│"
    echo "│  IP:     ${server}"
    echo "│  Port:   ${port}"
    echo "│  Secret: ${secret}"
    echo "└─────────────────────────────────────────────┘"
  done < "${DOMAINS_FILE}"

  if (( found == 0 )); then
    echo ""
    echo "  ⚠️  Нет активных секретов для пользователя"
    return 0
  fi

  # Инструкция
  echo ""
  echo "╔═════════════════════════════════════════════╗"
  echo "║  Как подключить прокси в Telegram           ║"
  echo "╠═════════════════════════════════════════════╣"
  echo "║"
  echo "║  📱 Мобильная версия (Android / iOS):"
  echo "║  1. Откройте ссылку tg://proxy?... на"
  echo "║     устройстве — Telegram откроется"
  echo "║     автоматически с предложением добавить"
  echo "║     прокси."
  echo "║  2. Нажмите «Подключить» / «Connect»"
  echo "║"
  echo "║  Вручную (Android):"
  echo "║  1. Настройки → Данные и память"
  echo "║  2. Прокси-сервер → Использовать прокси"
  echo "║  3. Добавить прокси → MTProto"
  echo "║  4. Введите IP, Port, Secret"
  echo "║"
  echo "║  Вручную (iOS):"
  echo "║  1. Настройки → Данные и память"
  echo "║  2. Настройки прокси → Включить"
  echo "║  3. Добавить прокси → MTProto"
  echo "║  4. Введите данные"
  echo "║"
  echo "║  🖥 Десктоп (Windows / macOS / Linux):"
  echo "║  1. Кликните по ссылке tg://proxy?..."
  echo "║  2. Нажмите «Подключить»"
  echo "║"
  echo "║  Вручную (Desktop):"
  echo "║  1. Настройки → Продвинутые → Тип прокси"
  echo "║  2. MTProto Proxy"
  echo "║  3. Введите IP, Port, Secret"
  echo "║  4. Сохранить"
  echo "║"
  echo "╚═════════════════════════════════════════════╝"
}

# ─────────────────────────────────────────────────────────────────────────────
# user_link — ссылка для пользователя
# ─────────────────────────────────────────────────────────────────────────────
user_link() {
  local username="$1"
  local domain="${2:-}"
  local server="${3:-}"

  local line
  line=$(user_find "$username")
  if [[ -z "$line" ]]; then
    log_error "Пользователь '${username}' не найден"
    return 1
  fi

  if [[ -z "$server" ]]; then
    server=$(get_server_ip)
  fi

  if [[ -n "$domain" ]]; then
    local secret
    secret=$(secret_for_user_domain "$username" "$domain")
    if [[ -z "$secret" ]]; then
      log_error "Нет секрета для '${username}' на домене '${domain}'"
      return 1
    fi
    local cname port
    cname=$(container_name_for "$domain" "$username")
    port=$(docker_container_port "$cname" 2>/dev/null || echo "$DEFAULT_PORT")
    printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$server" "$port" "$secret"
  else
    domain_links_for_user "$username" "$server"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_links_for_user
# ─────────────────────────────────────────────────────────────────────────────
domain_links_for_user() {
  local username="$1"
  local server="${2:-}"
  if [[ -z "$server" ]]; then
    server=$(get_server_ip)
  fi

  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    log_error "Нет доменов"
    return 1
  fi

  local found=0
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue

    local secret
    secret=$(secret_for_user_domain "$username" "$domain")
    [[ -z "$secret" ]] && continue

    local cname port
    cname=$(container_name_for "$domain" "$username")
    port=$(docker_container_port "$cname" 2>/dev/null || echo "$DEFAULT_PORT")

    echo "  ${domain}:"
    printf '    tg://proxy?server=%s&port=%s&secret=%s\n' "$server" "$port" "$secret"
    echo ""
    found=$(( found + 1 ))
  done < "${DOMAINS_FILE}"

  if (( found == 0 )); then
    log_warn "Нет активных секретов для пользователя"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# user_revoke
# ─────────────────────────────────────────────────────────────────────────────
user_revoke() {
  local username="$1"

  local line
  line=$(user_find "$username")
  if [[ -z "$line" ]]; then
    log_error "Пользователь '${username}' не найден"
    return 1
  fi

  local count=0
  secrets_for_user "$username" 2>/dev/null | while IFS=',' read -r domain secret; do
    [[ -z "$secret" ]] && continue
    secrets_revoke_user_domain "$username" "$domain"
    local cname
    cname=$(container_name_for "$domain" "$username")
    docker_remove_container "$cname"
    count=$(( count + 1 ))
  done

  log_info "Секреты пользователя '${username}' отозваны"
}

# ─────────────────────────────────────────────────────────────────────────────
# user_rotate
# ─────────────────────────────────────────────────────────────────────────────
user_rotate() {
  local username="$1"

  local line
  line=$(user_find "$username")
  if [[ -z "$line" ]]; then
    log_error "Пользователь '${username}' не найден"
    return 1
  fi

  log_step "Перегенерация секретов для '${username}'..."

  local domain_count=0
  if [[ -f "${DOMAINS_FILE}" ]]; then
    while IFS= read -r domain || [[ -n "$domain" ]]; do
      domain=$(printf '%s' "$domain" | tr -d '\r')
      [[ -z "$domain" ]] && continue
      [[ "$domain" == "domain" ]] && continue

      # Отзываем старый
      secrets_revoke_user_domain "$username" "$domain"
      local cname
      cname=$(container_name_for "$domain" "$username")
      docker_remove_container "$cname"

      # Создаём новый
      secret_add_for "$domain" "$username" "rotated"
      local secret
      secret=$(secret_for_user_domain "$username" "$domain")
      if [[ -n "$secret" ]]; then
        local port
        port=$(find_free_port 443 8443 8444 8445 8446 8447 8448 8449 8450) || return 1
        docker_start_container "$domain" "$username" "$secret" "$port"
        domain_count=$(( domain_count + 1 ))
      fi
    done < "${DOMAINS_FILE}"
  fi

  if (( domain_count > 0 )); then
    log_info "Секреты перегенерированы для ${domain_count} домен(ов)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal
# ─────────────────────────────────────────────────────────────────────────────
_user_set_field() {
  local uid="$1" field="$2" value="$3"

  local tmp
  tmp="$(mktemp "${USERS_FILE}.tmp.XXXXXX")"
  head -1 "${USERS_FILE}" > "$tmp"

  local first=true
  while IFS=',' read -r id username created status comment; do
    if $first; then first=false; continue; fi
    if [[ "$id" == "$uid" ]]; then
      case "$field" in
        id) id="$value" ;; username) username="$value" ;; created) created="$value" ;;
        status) status="$value" ;; comment) comment="$value" ;;
      esac
    fi
    printf '%s,%s,%s,%s,%s\n' "$id" "$username" "$created" "$status" "$comment" >> "$tmp"
  done < "${USERS_FILE}"

  chmod 600 "$tmp"
  mv -f "$tmp" "${USERS_FILE}"
}
