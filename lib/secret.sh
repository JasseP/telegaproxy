#!/usr/bin/env bash
###############################################################################
# lib/secret.sh — управление секретами MTProxy (v3: multi-user)
#
# Хранение: state/secrets.csv
# Формат CSV: id,secret,type,domain,user_id,created_at,expires_at,status,comment
#
# Отличие от v2: добавлена колонка user_id — привязка секрета к пользователю.
# Один контейнер на домен (alexbers/mtprotoproxy), конфиг содержит все секреты.
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Инициализация
# ─────────────────────────────────────────────────────────────────────────────
secrets_init() {
  if [[ ! -f "${SECRETS_FILE}" ]]; then
    atomic_write "${SECRETS_FILE}" "id,secret,type,domain,user_id,created_at,expires_at,status,comment"
    log_info "Создан ${SECRETS_FILE}"
    return 0
  fi

  # Всегда пытаcь мигрировать (idempotent)
  _secrets_migrate_v2_v3
}

# ── Миграция v2 → v3: добавить колонку user_id ────────────────────────────
_secrets_migrate_v2_v3() {
  # Проверяем первую строку данных
  local first_data
  first_data=$(tail -n +2 "${SECRETS_FILE}" | head -1)
  [[ -z "$first_data" ]] && return 0

  local field_count
  field_count=$(echo "$first_data" | awk -F',' '{print NF}')

  if [[ "$field_count" == "8" ]]; then
    log_info "Миграция секретов: v2 → v3 (добавление user_id)..."
    local tmp
    tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
    echo "id,secret,type,domain,user_id,created_at,expires_at,status,comment" > "$tmp"
    # Вставляем пустой user_id между domain(4) и created_at(5)
    tail -n +2 "${SECRETS_FILE}" | while IFS= read -r line; do
      # Заменяем только первую запятую после 4-го поля на ",,"
      echo "$line" | awk -F',' '{
        printf "%s,%s,%s,%s,,%s,%s,%s,%s\n", $1,$2,$3,$4,$5,$6,$7,$8
      }' >> "$tmp"
    done
    chmod 600 "$tmp"
    mv -f "$tmp" "${SECRETS_FILE}"
    log_info "Миграция завершена"
  fi
}

# ── migrate_secrets — публичная команда миграции ────────────────────────────
migrate_secrets() {
  _secrets_migrate_v2_v3
}

# ─────────────────────────────────────────────────────────────────────────────
# Утилиты
# ─────────────────────────────────────────────────────────────────────────────

_secret_id() {
  printf 's_%s' "$(date +%s)_$$"
}

_secrets_check() {
  if [[ ! -f "${SECRETS_FILE}" ]]; then
    log_error "Файл секретов не найден. Выполните: mtpx init"
    return 1
  fi
}

# Номера колонок (v3: добавлена user_id)
# id,secret,type,domain,user_id,created_at,expires_at,status,comment
_CSV_ID=1; _CSV_SECRET=2; _CSV_TYPE=3; _CSV_DOMAIN=4; _CSV_USER_ID=5
_CSV_CREATED=6; _CSV_EXPIRES=7; _CSV_STATUS=8; _CSV_COMMENT=9

secret_count() {
  _secrets_check || return 1
  tail -n +2 "${SECRETS_FILE}" | wc -l
}

active_secrets() {
  _secrets_check || return 1
  tail -n +2 "${SECRETS_FILE}" | awk -F',' '$8=="active"'
}

# ─────────────────────────────────────────────────────────────────────────────
# ADD — добавление секрета
# ─────────────────────────────────────────────────────────────────────────────
secret_add() {
  _secrets_check || return 1
  local type="${1:-fake_tls}"
  local domain="${2:-}"
  local comment="${3:-}"

  if [[ -z "$domain" ]]; then
    domain=$(domain_current 2>/dev/null || echo "$DEFAULT_DOMAIN")
  fi

  local secret
  case "$type" in
    fake_tls) secret=$(generate_fake_tls_secret "$domain") ;;
    simple)   secret=$(generate_simple_secret) ;;
    secure)   secret=$(generate_fake_tls_secret "$domain") ;;
    *)
      log_error "Неизвестный тип: $type (fake_tls|simple|secure)"
      return 1
      ;;
  esac

  local id created_at
  id=$(_secret_id)
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  cat "${SECRETS_FILE}" > "$tmp"
  # id,secret,type,domain,user_id,created_at,expires_at,status,comment
  printf '%s,%s,%s,%s,,%s,,%s,%s\n' \
    "$id" "$secret" "$type" "$domain" "$created_at" "active" "$comment" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"

  log_info "Секрет добавлен: id=${id} type=${type} domain=${domain}"
  echo "  ID:      ${id}"
  echo "  Type:    ${type}"
  echo "  Domain:  ${domain}"
  echo "  Secret:  $(mask_secret "$secret")"
}

# ─────────────────────────────────────────────────────────────────────────────
# LIST
# ─────────────────────────────────────────────────────────────────────────────
secret_list() {
  _secrets_check || return 1
  local filter="${1:-}"

  echo "┌──────┬────────────────────────────────────┬──────────┬────────────┬───────────┬──────────┐"
  echo "│ ID   │ Secret                             │ Type     │ Domain     │ Created   │ Status   │"
  echo "├──────┼────────────────────────────────────┼──────────┼────────────┼───────────┼──────────┤"

  local first=true
  while IFS=',' read -r id secret type domain user_id created expires status comment; do
    if $first; then first=false; continue; fi
    if [[ -n "$filter" && "$status" != "$filter" ]]; then
      continue
    fi
    printf "│ %-4s │ %-34s │ %-8s │ %-10s │ %-9s │ %-8s │\n" \
      "$id" "$(mask_secret "$secret")" "$type" "$domain" "${created:0:10}" "$status"
  done < "${SECRETS_FILE}"

  echo "└──────┴────────────────────────────────────┴──────────┴────────────┴───────────┴──────────┘"
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW
# ─────────────────────────────────────────────────────────────────────────────
secret_show() {
  _secrets_check || return 1
  local reveal=false
  local secret_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reveal|-r) reveal=true; shift ;;
      *) secret_id="$1"; shift ;;
    esac
  done

  if [[ -z "$secret_id" ]]; then
    log_error "Укажите ID секрета: mtpx secret show <id>"
    return 1
  fi

  local line
  line=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1==id')
  if [[ -z "$line" ]]; then
    log_error "Секрет с ID '${secret_id}' не найден"
    return 1
  fi

  IFS=',' read -r id secret type domain user_id created expires status comment <<< "$line"

  echo "  ID:       ${id}"
  echo "  Type:     ${type}"
  echo "  Domain:   ${domain}"
  if $reveal; then
    echo "  Secret:   ${secret}  [ПОЛНЫЙ]"
  else
    echo "  Secret:   $(mask_secret "$secret")"
    echo "  (полный: mtpx secret show --reveal ${id})"
  fi
  echo "  User:     ${user_id:-system}"
  echo "  Created:  ${created}"
  echo "  Expires:  ${expires:-never}"
  echo "  Status:   ${status}"
  echo "  Comment:  ${comment:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# REVOKE / ROTATE / DELETE
# ─────────────────────────────────────────────────────────────────────────────
secret_revoke() {
  _secrets_check || return 1
  local secret_id="$1"
  _secret_set_field "$secret_id" "status" "revoked"
  log_info "Секрет ${secret_id} отозван"
}

secret_rotate() {
  _secrets_check || return 1
  local secret_id="$1"
  local type="${2:-}"

  local line
  line=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1==id')
  if [[ -z "$line" ]]; then
    log_error "Секрет с ID '${secret_id}' не найден"
    return 1
  fi

  IFS=',' read -r _ _ old_type old_domain old_user_id _ _ _ _ <<< "$line"
  local rotate_type="${type:-$old_type}"

  _secret_set_field "$secret_id" "status" "revoked"
  secret_add "$rotate_type" "$old_domain" "rotated from ${secret_id}"
}

secret_delete() {
  _secrets_check || return 1
  local secret_id="$1"

  local line
  line=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1==id')
  if [[ -z "$line" ]]; then
    log_error "Секрет с ID '${secret_id}' не найден"
    return 1
  fi

  local active
  active=$(active_secrets | wc -l)
  local status
  status=$(echo "$line" | cut -d',' -f8)
  if [[ "$status" == "active" ]] && (( active <= 1 )); then
    log_error "Нельзя удалить последний активный секрет."
    return 1
  fi

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  head -1 "${SECRETS_FILE}" > "$tmp"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1!=id' >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"

  log_info "Секрет ${secret_id} удалён"
}

# ─────────────────────────────────────────────────────────────────────────────
# LINK
# ─────────────────────────────────────────────────────────────────────────────
secret_link() {
  _secrets_check || return 1
  local secret_id="${1:-}"
  local server="${2:-}"
  local port="${3:-}"

  if [[ -z "$secret_id" ]]; then
    local first_active
    first_active=$(active_secrets | head -1)
    if [[ -z "$first_active" ]]; then
      log_error "Нет активных секретов"
      return 1
    fi
    secret_id=$(echo "$first_active" | cut -d',' -f1)
  fi

  local line
  line=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1==id')
  if [[ -z "$line" ]]; then
    log_error "Секрет с ID '${secret_id}' не найден"
    return 1
  fi

  IFS=',' read -r id secret _ _ _ _ _ status _ <<< "$line"
  if [[ "$status" != "active" ]]; then
    log_warn "Секрет ${secret_id} имеет статус: ${status}"
  fi

  if [[ -z "$server" ]]; then
    server=$(get_server_ip)
  fi
  if [[ -z "$port" ]]; then
    port=$(runtime_get "PORT")
    port="${port:-$DEFAULT_PORT}"
  fi

  printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$server" "$port" "$secret"
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal: _secret_set_field
# ─────────────────────────────────────────────────────────────────────────────
_secret_set_field() {
  local secret_id="$1" field="$2" value="$3"

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  head -1 "${SECRETS_FILE}" > "$tmp"

  local first=true
  while IFS=',' read -r id secret type domain user_id created expires status comment; do
    if $first; then first=false; continue; fi
    if [[ "$id" == "$secret_id" ]]; then
      case "$field" in
        id) id="$value" ;; secret) secret="$value" ;; type) type="$value" ;;
        domain) domain="$value" ;; user_id) user_id="$value" ;;
        created) created="$value" ;; expires) expires="$value" ;;
        status) status="$value" ;; comment) comment="$value" ;;
      esac
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$id" "$secret" "$type" "$domain" "$user_id" "$created" "$expires" "$status" "$comment" >> "$tmp"
  done < "${SECRETS_FILE}"

  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

# =============================================================================
# v3: User-based secret helpers
# =============================================================================

# ── secrets_add_raw — добавить запись в CSV напрямую ─────────────────────────
secrets_add_raw() {
  _secrets_check || return 1
  local id="$1" secret="$2" type="$3" domain="$4" user_id="$5" created="$6" status="$7" comment="$8"
  local expires="${9:-}"

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  cat "${SECRETS_FILE}" > "$tmp"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$id" "$secret" "$type" "$domain" "$user_id" "$created" "$expires" "$status" "$comment" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

# ── secrets_active_for_domain — получить ВСЕ активные секреты для домена ────
# Возвращает строки: secret,user_id (для генерации конфига прокси)
# ─────────────────────────────────────────────────────────────────────────────
secrets_active_for_domain() {
  _secrets_check || return 1
  local domain="$1"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v d="$domain" '$4==d && $8=="active" {print $2","$5}'
}

# ── secrets_active_for_user_domain — секрет пользователя для домена ──────────
secrets_active_for_user_domain() {
  _secrets_check || return 1
  local uid="$1"
  local domain="$2"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v u="$uid" -v d="$domain" '$4==d && $5==u && $8=="active" {print $2; exit}'
}

# ── secrets_masked_for_domain — маскированный первый секрет домена ───────────
secrets_masked_for_domain() {
  _secrets_check || return 1
  local domain="$1"
  local secret
  secret=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v d="$domain" '$4==d && $8=="active" {print $2; exit}')
  if [[ -n "$secret" ]]; then
    mask_secret "$secret"
  else
    echo "none"
  fi
}

# ── secrets_count_for_domain — количество секретов для домена ────────────────
secrets_count_for_domain() {
  _secrets_check || return 0
  local domain="$1"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v d="$domain" '$4==d' | wc -l
}

# ── secrets_remove_domain — удалить все секреты для домена ───────────────────
secrets_remove_domain() {
  _secrets_check || return 1
  local domain="$1"

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  head -1 "${SECRETS_FILE}" > "$tmp"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v d="$domain" '$4!=d' >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

# ── secrets_count_for_user ───────────────────────────────────────────────────
secrets_count_for_user() {
  _secrets_check || return 0
  local uid="$1"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v u="$uid" '$5==u && $8=="active"' | wc -l
}

# ── secrets_revoke_user — отозвать все секреты пользователя ──────────────────
secrets_revoke_user() {
  _secrets_check || return 1
  local uid="$1"

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  head -1 "${SECRETS_FILE}" > "$tmp"

  local first=true
  while IFS=',' read -r id secret type domain user_id created expires status comment; do
    if $first; then first=false; continue; fi
    if [[ "$user_id" == "$uid" ]]; then
      status="revoked"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$id" "$secret" "$type" "$domain" "$user_id" "$created" "$expires" "$status" "$comment" >> "$tmp"
  done < "${SECRETS_FILE}"

  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

# ── secrets_count_for_user_active_domains ────────────────────────────────────
secrets_count_for_user_active_domains() {
  _secrets_check || return 0
  local uid="$1"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v u="$uid" '$5==u && $8=="active" {print $4}' | sort -u | wc -l
}
