#!/usr/bin/env bash
###############################################################################
# lib/user.sh — управление пользователями (v3: multi-user)
#
# Архитектура:
#   Каждый пользователь получает уникальный секрет для каждого домена.
#   Один контейнер на домен (alexbers/mtprotoproxy), конфиг содержит все секреты.
#
#   ya.ru       → mtproto-ya-ru       → secrets: user1=ee7961..., user2=ee7962...
#   google.com  → mtproto-google-com  → secrets: user1=ee676f..., user2=ee6770...
#
# Формат users.csv: id,username,created_at,status,comment
# Формат secrets.csv: id,secret,type,domain,user_id,created_at,expires_at,status,comment
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${MTPX_ROOT}/lib/config.sh"
# shellcheck source=lib/secret.sh
source "${MTPX_ROOT}/lib/secret.sh"

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
# Утилиты CSV пользователей
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

# Количество пользователей (без заголовка)
user_count() {
  _users_check || return 1
  local total
  total=$(tail -n +2 "${USERS_FILE}" | wc -l)
  echo "$total"
}

# Активные пользователи
active_users() {
  _users_check || return 1
  tail -n +2 "${USERS_FILE}" | awk -F',' '$4=="active"'
}

# Найти пользователя по username
user_find() {
  _users_check || return 1
  local username="$1"
  tail -n +2 "${USERS_FILE}" | awk -F',' -v u="$username" '$2==u'
}

# Получить ID пользователя по username
user_get_id() {
  local line
  line=$(user_find "$1")
  if [[ -n "$line" ]]; then
    echo "$line" | cut -d',' -f1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# user_add — создать пользователя + секреты для всех доменов
# ─────────────────────────────────────────────────────────────────────────────
# user_add <username> [comment]
#
# Что делает:
#   1. Создаёт запись в users.csv
#   2. Для каждого домена из domains.txt генерирует Fake TLS секрет
#   3. Сохраняет секреты в secrets.csv с привязкой user_id + domain
#   4. Перегенерирует конфиг прокси для всех доменов (docker_config_sync)
#   5. Перезапускает контейнеры (чтобы подхватить новые секреты)
# ─────────────────────────────────────────────────────────────────────────────
user_add() {
  local username="$1"
  local comment="${2:-}"

  if [[ -z "$username" ]]; then
    log_error "Укажите имя пользователя: mtpx user add <username>"
    return 1
  fi

  # Проверка: нет ли уже такого
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

  # Генерируем секреты для всех доменов
  if [[ -f "${DOMAINS_FILE}" ]]; then
    local domain_count=0
    while IFS= read -r domain || [[ -n "$domain" ]]; do
      domain=$(printf '%s' "$domain" | tr -d '\r')
      [[ -z "$domain" ]] && continue
      [[ "$domain" == "domain" ]] && continue

      domain_count=$(( domain_count + 1 ))
      _create_secret_for_user "$uid" "$username" "$domain"
    done < "${DOMAINS_FILE}"

    if (( domain_count > 0 )); then
      log_info "Создано секретов для ${domain_count} домен(ов)"
    else
      log_warn "Нет доменов. Секреты будут созданы при добавлении домена."
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# user_remove — удалить пользователя + все секреты
# ─────────────────────────────────────────────────────────────────────────────
# user_remove <username>
#
# Что делает:
#   1. Находит все секреты пользователя
#   2. Отзывает их (status → revoked)
#   3. Меняет статус пользователя на revoked
#   4. Перегенерирует конфиги прокси
#   5. Перезапускает контейнеры
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

  # Отзываем все секреты пользователя
  local secret_count
  secret_count=$(secrets_count_for_user "$uid")
  if (( secret_count > 0 )); then
    secrets_revoke_user "$uid"
    log_info "Отозвано секретов: ${secret_count}"
  fi

  # Меняем статус пользователя
  _user_set_field "$uid" "status" "revoked"

  log_info "Пользователь '${username}' удалён"
}

# ─────────────────────────────────────────────────────────────────────────────
# user_list — список всех пользователей
# ─────────────────────────────────────────────────────────────────────────────
user_list() {
  _users_check || return 1

  echo "┌──────┬──────────────────┬────────────┬──────────┬──────────┐"
  echo "│ ID   │ Username         │ Created    │ Status   │ Domains  │"
  echo "├──────┼──────────────────┼────────────┼──────────┼──────────┤"

  local first=true
  while IFS=',' read -r id username created status comment; do
    if $first; then first=false; continue; fi

    # Считаем активные домены пользователя
    local domains
    domains=$(secrets_count_for_user_active_domains "$id" 2>/dev/null || echo "0")

    printf "│ %-4s │ %-16s │ %-10s │ %-8s │ %-8s │\n" \
      "$id" "$username" "${created:0:10}" "$status" "$domains"
  done < "${USERS_FILE}"

  echo "└──────┴──────────────────┴────────────┴──────────┴──────────┘"
}

# ─────────────────────────────────────────────────────────────────────────────
# user_link — ссылка для пользователя (все домены или конкретный)
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

  local uid
  uid=$(echo "$line" | cut -d',' -f1)

  if [[ -z "$server" ]]; then
    server=$(get_server_ip)
  fi

  if [[ -n "$domain" ]]; then
    # Ссылка для конкретного домена
    local secret port
    secret=$(secrets_active_for_user_domain "$uid" "$domain")
    if [[ -z "$secret" ]]; then
      log_error "Нет секрета для пользователя '${username}' на домене '${domain}'"
      return 1
    fi
    local cname
    cname=$(container_name_for_domain "$domain")
    port=$(docker_container_port "$cname" 2>/dev/null || echo "$DEFAULT_PORT")
    printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$server" "$port" "$secret"
  else
    # Все ссылки
    domain_links_for_user "$uid" "$server"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_links_for_user — все ссылки пользователя
# ─────────────────────────────────────────────────────────────────────────────
domain_links_for_user() {
  local uid="$1"
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

    local secret port
    secret=$(secrets_active_for_user_domain "$uid" "$domain")
    [[ -z "$secret" ]] && continue

    local cname
    cname=$(container_name_for_domain "$domain")
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
# user_revoke — отозвать все секреты пользователя (без удаления)
# ─────────────────────────────────────────────────────────────────────────────
user_revoke() {
  local username="$1"

  local line
  line=$(user_find "$username")
  if [[ -z "$line" ]]; then
    log_error "Пользователь '${username}' не найден"
    return 1
  fi

  local uid
  uid=$(echo "$line" | cut -d',' -f1)

  local count
  count=$(secrets_count_for_user "$uid")
  if (( count > 0 )); then
    secrets_revoke_user "$uid"
    log_info "Отозвано ${count} секретов пользователя '${username}'"
  else
    log_warn "У пользователя '${username}' нет активных секретов"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# user_rotate — перегенерировать секреты пользователя
# ─────────────────────────────────────────────────────────────────────────────
user_rotate() {
  local username="$1"

  local line
  line=$(user_find "$username")
  if [[ -z "$line" ]]; then
    log_error "Пользователь '${username}' не найден"
    return 1
  fi

  local uid
  uid=$(echo "$line" | cut -d',' -f1)

  log_step "Перегенерация секретов для '${username}'..."

  # Отзываем старые
  secrets_revoke_user "$uid"

  # Создаём новые для всех доменов
  local domain_count=0
  if [[ -f "${DOMAINS_FILE}" ]]; then
    while IFS= read -r domain || [[ -n "$domain" ]]; do
      domain=$(printf '%s' "$domain" | tr -d '\r')
      [[ -z "$domain" ]] && continue
      [[ "$domain" == "domain" ]] && continue

      _create_secret_for_user "$uid" "$username" "$domain"
      domain_count=$(( domain_count + 1 ))
    done < "${DOMAINS_FILE}"
  fi

  if (( domain_count > 0 )); then
    log_info "Секреты перегенерированы для ${domain_count} домен(ов)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Внутренние функции
# ─────────────────────────────────────────────────────────────────────────────

# _create_secret_for_user — создать секрет для пользователя на конкретном домене
_create_secret_for_user() {
  local uid="$1"
  local username="$2"
  local domain="$3"

  local secret created_at sid
  secret=$(generate_fake_tls_secret "$domain")
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sid=$(_secret_id)

  # Проверяем, нет ли уже секрета для этого user+domain
  local existing
  existing=$(secrets_active_for_user_domain "$uid" "$domain")
  if [[ -n "$existing" ]]; then
    return 0  # уже есть
  fi

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  cat "${SECRETS_FILE}" > "$tmp"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$sid" "$secret" "fake_tls" "$domain" "$uid" "$created_at" "" "active" "user:${username}" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

# _user_set_field — изменить поле пользователя
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
