#!/usr/bin/env bash
###############################################################################
# lib/secret.sh — управление секретами MTProxy (v4: один секрет = один контейнер)
#
# Хранение: state/secrets.csv
# Формат CSV: id,secret,type,domain,username,created_at,expires_at,status,comment
#
# Каждая строка = один контейнер (domain + username).
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Инициализация
# ─────────────────────────────────────────────────────────────────────────────
secrets_init() {
  if [[ ! -f "${SECRETS_FILE}" ]]; then
    atomic_write "${SECRETS_FILE}" "id,secret,type,domain,username,created_at,expires_at,status,comment"
    log_info "Создан ${SECRETS_FILE}"
  fi
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

secret_count() {
  _secrets_check || return 1
  tail -n +2 "${SECRETS_FILE}" | wc -l
}

active_secrets() {
  _secrets_check || return 1
  tail -n +2 "${SECRETS_FILE}" | awk -F',' '$8=="active"'
}

# ─────────────────────────────────────────────────────────────────────────────
# Поиск секретов
# ─────────────────────────────────────────────────────────────────────────────

# Секрет для пользователя на домене
secret_for_user_domain() {
  _secrets_check || return 1
  local username="$1"
  local domain="$2"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v u="$username" -v d="$domain" \
    '$4==d && $5==u && $8=="active" {print $2; exit}'
}

# Все секреты для домена (все пользователи)
secrets_for_domain() {
  _secrets_check || return 1
  local domain="$1"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v d="$domain" '$4==d && $8=="active" {print $2","$5}'
}

# Все секреты пользователя (все домены)
secrets_for_user() {
  _secrets_check || return 1
  local username="$1"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v u="$username" '$5==u && $8=="active" {print $4","$2}'
}

# Количество секретов для домена
secrets_count_for_domain() {
  _secrets_check || return 0
  local domain="$1"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v d="$domain" '$4==d && $8=="active"' | wc -l
}

# Количество доменов пользователя
user_domain_count() {
  _secrets_check || return 0
  local username="$1"
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v u="$username" '$5==u && $8=="active" {print $4}' | sort -u | wc -l
}

# ─────────────────────────────────────────────────────────────────────────────
# Добавление секрета
# ─────────────────────────────────────────────────────────────────────────────
secret_add_for() {
  _secrets_check || return 1
  local domain="$1"
  local username="$2"
  local comment="${3:-}"

  # Проверяем, нет ли уже активного
  local existing
  existing=$(secret_for_user_domain "$username" "$domain")
  if [[ -n "$existing" ]]; then
    return 0
  fi

  local secret id created_at
  secret=$(generate_fake_tls_secret "$domain")
  id=$(_secret_id)
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  cat "${SECRETS_FILE}" > "$tmp"
  # id,secret,type,domain,username,created_at,expires_at,status,comment
  printf '%s,%s,%s,%s,%s,%s,,%s,%s\n' \
    "$id" "$secret" "fake_tls" "$domain" "$username" "$created_at" "active" "$comment" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Отзыв секретов
# ─────────────────────────────────────────────────────────────────────────────
secrets_revoke_for_domain() {
  _secrets_check || return 1
  local domain="$1"
  _secrets_set_field_where '$4==d' "d=$domain" "status" "revoked"
}

secrets_revoke_for_user() {
  _secrets_check || return 1
  local username="$1"
  _secrets_set_field_where '$5==u' "u=$username" "status" "revoked"
}

secrets_revoke_user_domain() {
  _secrets_check || return 1
  local username="$1"
  local domain="$2"
  _secrets_set_field_where '$4==d && $5==u' "d=$domain,u=$username" "status" "revoked"
}

# ─────────────────────────────────────────────────────────────────────────────
# Удаление секретов
# ─────────────────────────────────────────────────────────────────────────────
secrets_remove_for_domain() {
  _secrets_check || return 1
  local domain="$1"
  _secrets_remove_where '$4!=d' "d=$domain"
}

secrets_remove_for_user() {
  _secrets_check || return 1
  local username="$1"
  _secrets_remove_where '$5!=u' "u=$username"
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────
_secrets_set_field_where() {
  local condition="$1"
  local awk_vars="$2"
  local field="$3"
  local value="$4"

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  head -1 "${SECRETS_FILE}" > "$tmp"

  local first=true
  while IFS=',' read -r id secret type domain username created expires status comment; do
    if $first; then first=false; continue; fi
    # Проверяем условие через awk
    if echo "$id,$secret,$type,$domain,$username,$created,$expires,$status,$comment" | \
       awk -F',' "$condition" >/dev/null 2>&1; then
      case "$field" in
        id) id="$value" ;; secret) secret="$value" ;; type) type="$value" ;;
        domain) domain="$value" ;; username) username="$value" ;;
        created) created="$value" ;; expires) expires="$value" ;;
        status) status="$value" ;; comment) comment="$value" ;;
      esac
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$id" "$secret" "$type" "$domain" "$username" "$created" "$expires" "$status" "$comment" >> "$tmp"
  done < "${SECRETS_FILE}"

  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

_secrets_remove_where() {
  local condition="$1"
  local awk_vars="$2"

  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  head -1 "${SECRETS_FILE}" > "$tmp"
  # Оставляем только строки, которые НЕ соответствуют условию
  tail -n +2 "${SECRETS_FILE}" | while IFS= read -r line; do
    if ! echo "$line" | awk -F',' "$condition" >/dev/null 2>&1; then
      echo "$line" >> "$tmp"
    fi
  done
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# List / Show
# ─────────────────────────────────────────────────────────────────────────────
secret_list() {
  _secrets_check || return 1

  echo "┌──────┬────────────────────────────┬──────────┬────────────┬──────────┬──────────┐"
  echo "│ ID   │ Secret                     │ Type     │ Domain     │ User     │ Status   │"
  echo "├──────┼────────────────────────────┼──────────┼────────────┼──────────┼──────────┤"

  local first=true
  while IFS=',' read -r id secret type domain username created expires status comment; do
    if $first; then first=false; continue; fi
    printf "│ %-4s │ %-26s │ %-8s │ %-10s │ %-8s │ %-8s │\n" \
      "$id" "$(mask_secret "$secret")" "$type" "$domain" "$username" "$status"
  done < "${SECRETS_FILE}"

  echo "└──────┴────────────────────────────┴──────────┴────────────┴──────────┴──────────┘"
}

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
    log_error "Укажите ID: mtpx secret show <id>"
    return 1
  fi

  local line
  line=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1==id')
  if [[ -z "$line" ]]; then
    log_error "Секрет '${secret_id}' не найден"
    return 1
  fi

  IFS=',' read -r id secret type domain username created expires status comment <<< "$line"

  echo "  ID:       ${id}"
  echo "  Type:     ${type}"
  echo "  Domain:   ${domain}"
  echo "  User:     ${username}"
  if $reveal; then
    echo "  Secret:   ${secret}  [ПОЛНЫЙ]"
  else
    echo "  Secret:   $(mask_secret "$secret")"
  fi
  echo "  Created:  ${created}"
  echo "  Status:   ${status}"
}
