#!/usr/bin/env bash
###############################################################################
# lib/domain.sh — управление доменами (каждый домен = отдельный контейнер)
#
# Архитектура v2: Multi-Proxy
#   Каждый домен — это отдельный Docker-контейнер со своим секретом.
#   Пользователи получают разные ссылки для разных доменов.
#
#   ya.ru       → mtproxy-ya-ru       → SECRET=ee79612e7275...
#   google.com  → mtproxy-google-com  → SECRET=ee676f6f676c...
#   cloud.com   → mtproxy-cloud-com   → SECRET=ee636c6f7564...
#
# Контейнер именуется: mtproto-<normalized_domain>
#   нормализация: точка и тире заменяются на дефис, транслитерация не нужна.
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
# shellcheck source=lib/config_proxy.sh
source "${MTPX_ROOT}/lib/config_proxy.sh"
# shellcheck source=lib/user.sh
# Цикл разорван: user.sh больше не source-ит docker.sh
source "${MTPX_ROOT}/lib/user.sh" 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# domain_add — создать домен + контейнер + секреты для всех пользователей
# ─────────────────────────────────────────────────────────────────────────────
# domain_add <domain> [port]
#
# Что делает:
#   1. Проверяет валидность домена
#   2. Проверяет, нет ли уже такого контейнера
#   3. Для каждого активного пользователя генерирует Fake TLS секрет
#   4. Если пользователей нет — создаёт один системный секрет
#   5. Генерирует Python-конфиг для домена
#   6. Запускает Docker-контейнер с volume-монтированием конфига
# ─────────────────────────────────────────────────────────────────────────────
domain_add() {
  local domain="$1"
  local port="${2:-}"

  validate_domain "$domain"

  local cname
  cname=$(container_name_for_domain "$domain")
  if docker_container_exists "$cname"; then
    log_warn "Домен '${domain}' уже запущен (контейнер: ${cname})"
    echo "  Ссылка: mtpx domain links"
    return 0
  fi

  log_step "Создание домена '${domain}'..."

  # Определяем пользователей
  local users=""
  if [[ -f "${USERS_FILE}" ]]; then
    users=$(active_users 2>/dev/null || echo "")
  fi

  if [[ -n "$users" ]]; then
    # Создаём секреты для каждого пользователя
    local user_count=0
    while IFS=',' read -r uid username created status comment; do
      [[ -z "$uid" ]] && continue
      _create_secret_for_user "$uid" "$username" "$domain"
      user_count=$(( user_count + 1 ))
    done <<< "$users"
    log_info "Создано секретов для ${user_count} пользователей"
  else
    # Нет пользователей — создаём один системный секрет
    local secret id created_at
    secret=$(generate_fake_tls_secret "$domain")
    id=$(_secret_id)
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    secrets_add_raw "$id" "$secret" "fake_tls" "$domain" "" "$created_at" "" "active" "system (no users)"
    log_info "Создан системный секрет (нет пользователей)"
  fi

  # Запускаем контейнер (конфиг сгенерируется автоматически)
  log_step "Запуск контейнера ${cname}..."
  if docker_start_for_domain "$domain" "$cname" "$port"; then
    log_info "Домен '${domain}' запущен"
    echo ""
    echo "  Все ссылки: mtpx domain links"
    echo "  Ссылки по пользователю: mtpx user link <username>"
  else
    log_error "Не удалось запустить контейнер для '${domain}'"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# _create_secret_for_user — создать секрет для пользователя на домене
# ─────────────────────────────────────────────────────────────────────────────
_create_secret_for_user() {
  local uid="$1"
  local username="$2"
  local domain="$3"

  # Проверяем, нет ли уже секрета
  local existing
  existing=$(secrets_active_for_user_domain "$uid" "$domain" 2>/dev/null || echo "")
  if [[ -n "$existing" ]]; then
    return 0
  fi

  local secret created_at sid
  secret=$(generate_fake_tls_secret "$domain")
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sid=$(_secret_id)

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  cat "${SECRETS_FILE}" > "$tmp"
  # id,secret,type,domain,user_id,created_at,expires_at,status,comment
  printf '%s,%s,%s,%s,%s,%s,,%s,%s\n' \
    "$sid" "$secret" "fake_tls" "$domain" "$uid" "$created_at" "active" "user:${username}" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_remove — удалить домен + контейнер + секреты
# ─────────────────────────────────────────────────────────────────────────────
# domain_remove <domain>
#
# Что делает:
#   1. Находит контейнер для домена
#   2. Останавливает и удаляет его
#   3. Отзывает все секреты для этого домена
#   4. Удаляет секреты из CSV
# ─────────────────────────────────────────────────────────────────────────────
domain_remove() {
  local domain="$1"

  validate_domain "$domain"

  local cname
  cname=$(container_name_for_domain "$domain")

  if ! docker_container_exists "$cname"; then
    log_warn "Контейнер для домена '${domain}' не найден"
  else
    log_step "Остановка контейнера ${cname}..."
    docker_stop_container "$cname"
    docker_remove_container "$cname"
    log_info "Контейнер ${cname} удалён"
  fi

  # Удаляем все секреты для этого домена
  local count
  count=$(secrets_count_for_domain "$domain")
  if (( count > 0 )); then
    secrets_remove_domain "$domain"
    log_info "Удалено секретов: ${count}"
  fi

  # Удаляем конфиг прокси
  remove_proxy_config "$domain"

  log_info "Домен '${domain}' полностью удалён"
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_list — список всех доменов с их статусом
# ─────────────────────────────────────────────────────────────────────────────
# Выводит таблицу: домен, контейнер, статус, порт, секрет(маскированный), ссылка
# ─────────────────────────────────────────────────────────────────────────────
domain_list() {
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    echo "  Нет доменов. Добавьте: mtpx domain add <domain>"
    return 0
  fi

  echo "┌──────────────────┬──────────────────────┬──────────┬──────┬───────────────────────────────┐"
  echo "│ Домен            │ Контейнер            │ Статус   │ Порт │ Secret                        │"
  echo "├──────────────────┼──────────────────────┼──────────┼──────┼───────────────────────────────┤"

  local has_domains=false
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    domain=$(printf '%s' "$domain" | tr -d '\r')
    [[ -z "$domain" ]] && continue
    [[ "$domain" == "domain" ]] && continue  # пропуск заголовка

    has_domains=true
    local cname cstatus port masked_secret

    cname=$(container_name_for_domain "$domain") || cname="unknown"
    cstatus=$(docker_container_status "$cname" 2>/dev/null) || cstatus="?"
    port=$(docker_container_port "$cname" 2>/dev/null) || port="-"
    masked_secret=$(secrets_masked_for_domain "$domain" 2>/dev/null) || masked_secret="none"

    printf "│ %-16s │ %-20s │ %-8s │ %-4s │ %-29s │\n" \
      "$domain" "$cname" "$cstatus" "$port" "$masked_secret"
  done < "${DOMAINS_FILE}"

  echo "└──────────────────┴──────────────────────┴──────────┴──────┴───────────────────────────────┘"

  if ! $has_domains; then
    echo "  Нет доменов. Добавьте: mtpx domain add <domain>"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_link — получить ссылку для конкретного домена
# ─────────────────────────────────────────────────────────────────────────────
# domain_link <domain> [server]
# ─────────────────────────────────────────────────────────────────────────────
domain_link() {
  local domain="$1"
  local server="${2:-}"

  validate_domain "$domain"

  # Получаем активный секрет для домена
  local secret
  secret=$(secrets_active_for_domain "$domain")
  if [[ -z "$secret" ]]; then
    log_error "Нет активных секретов для домена '${domain}'"
    return 1
  fi

  # Порт из контейнера
  local cname port
  cname=$(container_name_for_domain "$domain")
  port=$(docker_container_port "$cname" || echo "$DEFAULT_PORT")

  if [[ -z "$server" ]]; then
    server=$(get_server_ip)
  fi

  printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$server" "$port" "$secret"
}

# domain_links_all — все ссылки для всех доменов (первый секрет каждого)
domain_links_all() {
  local server="${1:-}"
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

    # secrets_active_for_domain теперь возвращает "secret,user_id"
    local first_secret
    first_secret=$(secrets_active_for_domain "$domain" 2>/dev/null | head -1 | cut -d',' -f1 || echo "")
    [[ -z "$first_secret" ]] && continue

    local cname port
    cname=$(container_name_for_domain "$domain")
    port=$(docker_container_port "$cname" 2>/dev/null || echo "$DEFAULT_PORT")

    echo "  ${domain}:"
    printf '    tg://proxy?server=%s&port=%s&secret=%s\n' "$server" "$port" "$first_secret"
    echo ""
    found=$(( found + 1 ))
  done < "${DOMAINS_FILE}"

  if (( found == 0 )); then
    log_warn "Нет активных секретов"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_link — получить ссылку для конкретного домена
# ─────────────────────────────────────────────────────────────────────────────
domain_link() {
  local domain="$1"
  local server="${2:-}"

  validate_domain "$domain"

  local secret
  secret=$(secrets_active_for_domain "$domain" 2>/dev/null | head -1 | cut -d',' -f1 || echo "")
  if [[ -z "$secret" ]]; then
    log_error "Нет активных секретов для домена '${domain}'"
    return 1
  fi

  local cname port
  cname=$(container_name_for_domain "$domain")
  port=$(docker_container_port "$cname" 2>/dev/null || echo "$DEFAULT_PORT")

  if [[ -z "$server" ]]; then
    server=$(get_server_ip)
  fi

  printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$server" "$port" "$secret"
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_restart / domain_stop / domain_start / domain_logs — операции на домен
# ─────────────────────────────────────────────────────────────────────────────
domain_restart() {
  local domain="$1"
  local cname
  cname=$(container_name_for_domain "$domain")
  docker_restart_container "$cname"
}

domain_stop() {
  local domain="$1"
  local cname
  cname=$(container_name_for_domain "$domain")
  if docker_container_running "$cname"; then
    log_step "Остановка ${cname}..."
    docker_stop_container "$cname"
    if docker_container_running "$cname"; then
      log_error "Не удалось остановить ${cname}"
      return 1
    else
      log_info "Домен '${domain}' остановлен"
    fi
  else
    log_warn "Контейнер ${cname} уже не запущен"
  fi
}

domain_start() {
  local domain="$1"
  local cname
  cname=$(container_name_for_domain "$domain")
  docker_start_for_domain "$domain" "$cname"
}

domain_logs() {
  local domain="$1"
  local lines="${2:-20}"
  local cname
  cname=$(container_name_for_domain "$domain")
  docker_container_logs "$cname" "$lines"
}

# ─────────────────────────────────────────────────────────────────────────────
# domains_init — инициализация файла доменов
# ─────────────────────────────────────────────────────────────────────────────
domains_init() {
  if [[ ! -f "${DOMAINS_FILE}" ]]; then
    atomic_write "${DOMAINS_FILE}" "domain"
    log_info "Создан ${DOMAINS_FILE}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_list_raw — вывести все домены (без заголовка, без пустых строк)
# ─────────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# add_domain_to_list — добавить домен в domains.txt (атомарно)
# ─────────────────────────────────────────────────────────────────────────────
add_domain_to_list() {
  local domain="$1"

  # Проверка дубликата
  if [[ -f "${DOMAINS_FILE}" ]] && grep -qxF "$domain" "${DOMAINS_FILE}" 2>/dev/null; then
    return 0  # уже есть
  fi

  local tmp
  tmp="$(mktemp "${DOMAINS_FILE}.tmp.XXXXXX")"
  if [[ -f "${DOMAINS_FILE}" ]]; then
    cat "${DOMAINS_FILE}" > "$tmp"
  fi
  printf '%s\n' "$domain" >> "$tmp"
  mv -f "$tmp" "${DOMAINS_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# remove_domain_from_list — удалить домен из domains.txt
# ─────────────────────────────────────────────────────────────────────────────
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
