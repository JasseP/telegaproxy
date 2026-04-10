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

# ─────────────────────────────────────────────────────────────────────────────
# Утилиты
# ─────────────────────────────────────────────────────────────────────────────

# ── normalize_domain — преобразовать домен в имя контейнера ──────────────────
# ya.ru → ya-ru
# cloudflare.com → cloudflare-com
# sub.domain.com → sub-domain-com
# ─────────────────────────────────────────────────────────────────────────────
normalize_domain() {
  printf '%s' "$1" | tr '.' '-' | tr '_' '-' | tr '[:upper:]' '[:lower:]'
}

# ── container_name_for_domain — полное имя контейнера ────────────────────────
container_name_for_domain() {
  local norm
  norm=$(normalize_domain "$1")
  printf 'mtproto-%s' "$norm"
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_add — создать домен + контейнер + секрет
# ─────────────────────────────────────────────────────────────────────────────
# domain_add <domain> [port]
#
# Что делает:
#   1. Проверяет валидность домена
#   2. Проверяет, нет ли уже такого контейнера
#   3. Генерирует Fake TLS секрет для домена
#   4. Сохраняет секрет в secrets.csv
#   5. Запускает Docker-контейнер
#   6. Выводит ссылку для подключения
# ─────────────────────────────────────────────────────────────────────────────
domain_add() {
  local domain="$1"
  local port="${2:-}"

  # Валидация
  validate_domain "$domain"

  # Проверяем, не существует ли уже такой контейнер
  local cname
  cname=$(container_name_for_domain "$domain")
  if docker_container_exists "$cname"; then
    log_warn "Домен '${domain}' уже запущен (контейнер: ${cname})"
    echo "  Ссылка: mtpx domain link ${domain}"
    return 0
  fi

  # Генерируем секрет
  log_step "Генерация секрета для '${domain}'..."
  local secret
  secret=$(generate_fake_tls_secret "$domain")

  # Сохраняем в CSV
  local id created_at
  id=$(_secret_id)
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  secrets_add_raw "$id" "$secret" "fake_tls" "$domain" "$created_at" "active" "auto-created by domain add"

  # Запускаем контейнер
  log_step "Запуск контейнера ${cname}..."
  if docker_start_for_domain "$domain" "$cname" "$secret" "$port"; then
    log_info "Домен '${domain}' запущен"
    echo ""
    echo "  Ссылка: mtpx domain link ${domain}"
  else
    log_error "Не удалось запустить контейнер для '${domain}'"
    # Отзываем секрет, т.к. контейнер не запустился
    _secret_set_field "$id" "status" "revoked"
    return 1
  fi
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

# ─────────────────────────────────────────────────────────────────────────────
# domain_links — все ссылки для всех доменов
# ─────────────────────────────────────────────────────────────────────────────
domain_links() {
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
    [[ "$domain" == "domain" ]] && continue  # заголовок CSV

    local secret
    secret=$(secrets_active_for_domain "$domain")
    [[ -z "$secret" ]] && continue

    local cname port
    cname=$(container_name_for_domain "$domain")
    port=$(docker_container_port "$cname" || echo "$DEFAULT_PORT")

    echo "  ${domain}:"
    printf '    tg://proxy?server=%s&port=%s&secret=%s\n' "$server" "$port" "$secret"
    echo ""
  done < "${DOMAINS_FILE}"
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
  local secret
  secret=$(secrets_active_for_domain "$domain")
  if [[ -z "$secret" ]]; then
    log_error "Нет секрета для домена '${domain}'"
    return 1
  fi
  if docker_start_for_domain "$domain" "$cname" "$secret"; then
    log_info "Домен '${domain}' запущен"
  else
    log_error "Не удалось запустить домен '${domain}'"
    return 1
  fi
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
