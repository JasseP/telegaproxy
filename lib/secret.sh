#!/usr/bin/env bash
###############################################################################
# lib/secret.sh — управление секретами MTProxy
#
# Хранение: state/secrets.csv
# Формат CSV: id,secret,type,domain,created_at,expires_at,status,comment
#
# Типы секретов:
#   fake_tls — Fake TLS (префикс ee + hex домена + random)
#   simple   — Простой 16-байтный hex
#   secure   — Тоже Fake TLS (алиас для совместимости)
#
# Статусы:
#   active   — Действующий секрет (используется прокси)
#   revoked  — Отозванный (не используется, но сохранён в истории)
#   expired  — Истёкший (автоматически не применяется, но можно реактивировать)
#
# Важно: полный секрет показывается только с флагом --reveal.
# По умолчанию — маскировка (первые 6 + последние 4 символа).
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Инициализация
# ─────────────────────────────────────────────────────────────────────────────

# ── secrets_init — создать secrets.csv с заголовком ──────────────────────────
# Если файл ещё не существует, создаём его с заголовочной строю CSV.
# Заголовок нужен для парсинга: по нему определяем позиции колонок.
# chmod 600 — защита содержимого от других пользователей.
# ─────────────────────────────────────────────────────────────────────────────
secrets_init() {
  if [[ ! -f "${SECRETS_FILE}" ]]; then
    atomic_write "${SECRETS_FILE}" "id,secret,type,domain,created_at,expires_at,status,comment"
    log_info "Создан ${SECRETS_FILE}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Внутренние утилиты CSV
# ─────────────────────────────────────────────────────────────────────────────

# ── _secret_id — сгенерировать уникальный ID секрета ─────────────────────────
# Формат: s_<unix_timestamp>_<PID>
# Timestamp гарантирует уникальность при последовательных вызовах,
# PID — при одновременных (если несколько процессов).
# ─────────────────────────────────────────────────────────────────────────────
_secret_id() {
  printf 's_%s' "$(date +%s)_$$"
}

# ── _secrets_check — убедиться, что файл секретов существует ─────────────────
# Все публичные функции вызывают эту проверку перед работой.
# Если файл не найден — подсказываем пользователю запустить `mtpx init`.
# ─────────────────────────────────────────────────────────────────────────────
_secrets_check() {
  if [[ ! -f "${SECRETS_FILE}" ]]; then
    log_error "Файл секретов не найден. Выполните: mtpx init"
    return 1
  fi
}

# ── Номера колонок CSV ──────────────────────────────────────────────────────
# Присваиваем именованные константы для читаемости.
# При парсинке IFS=',' read -r f1 f2 f3 ... используем эти номера.
# ─────────────────────────────────────────────────────────────────────────────
_CSV_ID=1; _CSV_SECRET=2; _CSV_TYPE=3; _CSV_DOMAIN=4
_CSV_CREATED=5; _CSV_EXPIRES=6; _CSV_STATUS=7; _CSV_COMMENT=8

# ── secret_count — количество записей (без заголовка) ────────────────────────
# tail -n +2 — пропускаем заголовок, wc -l — считаем строки.
# ─────────────────────────────────────────────────────────────────────────────
secret_count() {
  _secrets_check || return 1
  local total
  total=$(tail -n +2 "${SECRETS_FILE}" | wc -l)
  echo "$total"
}

# ── active_secrets — вывести все строки со статусом "active" ─────────────────
# awk -F',' '$7=="active"' — выбираем строки, где 7-я колонка (status) = active.
# Результат — полные CSV-строки, которые можно дальше парсить.
# ─────────────────────────────────────────────────────────────────────────────
active_secrets() {
  _secrets_check || return 1
  tail -n +2 "${SECRETS_FILE}" | awk -F',' '$7=="active"'
}

# ─────────────────────────────────────────────────────────────────────────────
# ADD — добавление нового секрета
# ─────────────────────────────────────────────────────────────────────────────
# secret_add [type] [domain] [comment]
#
# type   — fake_tls (по умолчанию), simple, secure
# domain — домен для Fake TLS (берётся текущий из domains.txt)
# comment — произвольная заметка (например, "для клиента X")
#
# Генерирует секрет нужного типа, создаёт запись в CSV с статусом "active".
# ─────────────────────────────────────────────────────────────────────────────
secret_add() {
  _secrets_check || return 1
  local type="${1:-fake_tls}"
  local domain="${2:-}"
  local comment="${3:-}"

  # Если домен не указан — берём текущий из конфига
  if [[ -z "$domain" ]]; then
    domain=$(domain_current 2>/dev/null || echo "$DEFAULT_DOMAIN")
  fi

  # Генерируем секрет в зависимости от типа
  local secret
  case "$type" in
    fake_tls) secret=$(generate_fake_tls_secret "$domain") ;;  # ee + hex(domain) + random
    simple)   secret=$(generate_simple_secret) ;;              # 16 байт hex
    secure)   secret=$(generate_fake_tls_secret "$domain") ;;  # алиас fake_tls
    *)
      log_error "Неизвестный тип: $type (fake_tls|simple|secure)"
      return 1
      ;;
  esac

  # Формируем метаданные
  local id created_at
  id=$(_secret_id)
  created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)  # ISO 8601, UTC

  # Атомарно добавляем строку в CSV
  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  cat "${SECRETS_FILE}" > "$tmp"
  # Формат: id,secret,type,domain,created_at,expires_at,status,comment
  # expires_at пока пустой (—), статус = active
  printf '%s,%s,%s,%s,%s,,%s,%s\n' \
    "$id" "$secret" "$type" "$domain" "$created_at" "active" "$comment" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"

  # Выводим информацию, но маскируем секрет
  log_info "Секрет добавлен: id=${id} type=${type} domain=${domain}"
  echo "  ID:      ${id}"
  echo "  Type:    ${type}"
  echo "  Domain:  ${domain}"
  echo "  Secret:  $(mask_secret "$secret")"
  echo ""
  echo "  Показать полностью: mtpx secret show --reveal ${id}"
}

# ─────────────────────────────────────────────────────────────────────────────
# LIST — вывод таблицы секретов
# ─────────────────────────────────────────────────────────────────────────────
# secret_list [status_filter]
#
# status_filter — если указан (active/revoked/expired), показываем только
# записи с этим статусом. Без фильтра — все записи.
#
# Вывод — форматированная таблица с замаскированными секретами.
# ─────────────────────────────────────────────────────────────────────────────
secret_list() {
  _secrets_check || return 1
  local filter="${1:-}"

  echo "┌──────┬────────────────────────────────────┬──────────┬────────────┬───────────┬──────────┐"
  echo "│ ID   │ Secret                             │ Type     │ Domain     │ Created   │ Status   │"
  echo "├──────┼────────────────────────────────────┼──────────┼────────────┼───────────┼──────────┤"

  local first=true
  while IFS=',' read -r id secret type domain created expires status comment; do
    # Пропускаем заголовочную строку CSV
    if $first; then first=false; continue; fi

    # Фильтр по статусу: если filter задан и не совпадает — пропускаем
    if [[ -n "$filter" && "$status" != "$filter" ]]; then
      continue
    fi

    # %-34s — маскированный секрет фиксированной ширины
    printf "│ %-4s │ %-34s │ %-8s │ %-10s │ %-9s │ %-8s │\n" \
      "$id" "$(mask_secret "$secret")" "$type" "$domain" "${created:0:10}" "$status"
  done < "${SECRETS_FILE}"

  echo "└──────┴────────────────────────────────────┴──────────┴────────────┴───────────┴──────────┘"
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW — подробная информация о секрете
# ─────────────────────────────────────────────────────────────────────────────
# secret_show [--reveal] <id>
#
# --reveal (-r) — показать полный секрет. Без этого флага — маскировка.
# Это ключевое требование безопасности: секрет не попадает в историю
# терминала или скриншоты случайно.
# ─────────────────────────────────────────────────────────────────────────────
secret_show() {
  _secrets_check || return 1
  local reveal=false
  local secret_id=""

  # Парсим аргументы: флаг --reveal может стоять до или после ID
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

  # Ищем строку по ID: awk по первой колонке
  local line
  line=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1==id')
  if [[ -z "$line" ]]; then
    log_error "Секрет с ID '${secret_id}' не найден"
    return 1
  fi

  # Разбираем CSV-строку
  IFS=',' read -r id secret type domain created expires status comment <<< "$line"

  echo "  ID:       ${id}"
  echo "  Type:     ${type}"
  echo "  Domain:   ${domain}"
  if $reveal; then
    echo "  Secret:   ${secret}  [ПОЛНЫЙ]"
  else
    echo "  Secret:   $(mask_secret "$secret")"
    echo "  (полный: mtpx secret show --reveal ${id})"
  fi
  echo "  Created:  ${created}"
  echo "  Expires:  ${expires:-never}"
  echo "  Status:   ${status}"
  echo "  Comment:  ${comment:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# REVOKE — отозвать секрет
# ─────────────────────────────────────────────────────────────────────────────
# secret_revoke <id>
#
# Меняет статус на "revoked". Запись остаётся в CSV для истории,
# но секрет больше не будет использоваться при `mtpx apply`
# (apply берёт только active секреты).
# ─────────────────────────────────────────────────────────────────────────────
secret_revoke() {
  _secrets_check || return 1
  local secret_id="$1"
  _secret_set_field "$secret_id" "status" "revoked"
  log_info "Секрет ${secret_id} отозван"
}

# ─────────────────────────────────────────────────────────────────────────────
# ROTATE — ротация секрета
# ─────────────────────────────────────────────────────────────────────────────
# secret_rotate <id> [new_type]
#
# Алгоритм:
#   1. Находим старую запись, определяем тип и домен
#   2. Отзываем старый секрет (status → revoked)
#   3. Создаём новый секрет того же типа и домена
#      с комментарием "rotated from <old_id>"
#
# Это позволяет бесшовно заменить скомпрометированный секрет.
# ─────────────────────────────────────────────────────────────────────────────
secret_rotate() {
  _secrets_check || return 1
  local secret_id="$1"
  local type="${2:-}"

  # Находим старую запись
  local line
  line=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1==id')
  if [[ -z "$line" ]]; then
    log_error "Секрет с ID '${secret_id}' не найден"
    return 1
  fi

  # Извлекаем тип и домен старого секрета
  IFS=',' read -r _ _ old_type old_domain _ _ _ _ <<< "$line"
  local rotate_type="${type:-$old_type}"
  local rotate_domain="$old_domain"

  # Отзываем старый
  _secret_set_field "$secret_id" "status" "revoked"

  # Создаём новый (с комментарием о ротации)
  secret_add "$rotate_type" "$rotate_domain" "rotated from ${secret_id}"
}

# ─────────────────────────────────────────────────────────────────────────────
# DELETE — удалить секрет из CSV
# ─────────────────────────────────────────────────────────────────────────────
# secret_delete <id>
#
# Полностью удаляет строку из CSV (в отличие от revoke).
# Защита: нельзя удалить последний активный секрет — прокси останется
# без секрета. Сначала нужно добавить новый.
# ─────────────────────────────────────────────────────────────────────────────
secret_delete() {
  _secrets_check || return 1
  local secret_id="$1"

  # Находим запись
  local line
  line=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1==id')
  if [[ -z "$line" ]]; then
    log_error "Секрет с ID '${secret_id}' не найден"
    return 1
  fi

  # Проверяем, не последний ли это активный секрет
  local total
  total=$(secret_count)
  local active
  active=$(active_secrets | wc -l)

  local status
  status=$(echo "$line" | cut -d',' -f7)
  if [[ "$status" == "active" ]] && (( active <= 1 )); then
    log_error "Нельзя удалить последний активный секрет. Сначала добавьте новый."
    return 1
  fi

  # Перезаписываем CSV без этой строки
  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  head -1 "${SECRETS_FILE}" > "$tmp"  # Заголовок
  tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1!=id' >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"

  log_info "Секрет ${secret_id} удалён"
}

# ─────────────────────────────────────────────────────────────────────────────
# LINK — сгенерировать ссылку tg:// для подключения
# ─────────────────────────────────────────────────────────────────────────────
# secret_link [id] [server] [port]
#
# Формат ссылки:
#   tg://proxy?server=<IP>&port=<PORT>&secret=<SECRET>
#
# Если ID не указан — берём первый активный секрет.
# Если сервер не указан — определяем публичный IP через curl.
# Если порт не указан — берём из runtime.env.
# ─────────────────────────────────────────────────────────────────────────────
secret_link() {
  _secrets_check || return 1
  local secret_id="${1:-}"
  local server="${2:-}"
  local port="${3:-}"

  # Если ID не указан — берём первый активный секрет
  if [[ -z "$secret_id" ]]; then
    local first_active
    first_active=$(active_secrets | head -1)
    if [[ -z "$first_active" ]]; then
      log_error "Нет активных секретов"
      return 1
    fi
    secret_id=$(echo "$first_active" | cut -d',' -f1)
  fi

  # Находим секрет по ID
  local line
  line=$(tail -n +2 "${SECRETS_FILE}" | awk -F',' -v id="$secret_id" '$1==id')
  if [[ -z "$line" ]]; then
    log_error "Секрет с ID '${secret_id}' не найден"
    return 1
  fi

  IFS=',' read -r id secret _ _ _ _ status _ <<< "$line"

  if [[ "$status" != "active" ]]; then
    log_warn "Секрет ${secret_id} имеет статус: ${status}"
  fi

  # Определяем сервер и порт, если не указаны
  if [[ -z "$server" ]]; then
    server=$(get_server_ip)
  fi
  if [[ -z "$port" ]]; then
    port=$(runtime_get "PORT")
    port="${port:-$DEFAULT_PORT}"
  fi

  # Формируем ссылку (секрет в открытом виде — это необходимо для tg://)
  local link="tg://proxy?server=${server}&port=${port}&secret=${secret}"
  echo "$link"
}

# ─────────────────────────────────────────────────────────────────────────────
# _secret_set_field — внутренняя: изменить поле секрета в CSV
# ─────────────────────────────────────────────────────────────────────────────
# _secret_set_field <id> <field_name> <new_value>
#
# Перезаписывает весь CSV, заменяя значение нужного поля у нужной записи.
# Почему не sed? Потому что CSV — без разделителей между полями, и sed
# может заменить не то. Здесь парсим построчно, меняем нужную переменную,
# и собираем обратно.
#
# Атомарная запись (temp + mv) гарантирует целостность файла.
# ─────────────────────────────────────────────────────────────────────────────
_secret_set_field() {
  local secret_id="$1" field="$2" value="$3"

  # Определяем номер колонки (на всякий случай, хотя ниже используем имена)
  local col
  case "$field" in
    id) col=$_CSV_ID ;; secret) col=$_CSV_SECRET ;; type) col=$_CSV_TYPE ;;
    domain) col=_CSV_DOMAIN ;; created) col=$_CSV_CREATED ;; expires) col=$_CSV_EXPIRES ;;
    status) col=$_CSV_STATUS ;; comment) col=$_CSV_COMMENT ;;
    *) log_error "Неизвестное поле: $field"; return 1 ;;
  esac

  # Перезаписываем CSV
  local tmp
  tmp="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
  head -1 "${SECRETS_FILE}" > "$tmp"  # Заголовок без изменений

  local first=true
  while IFS=',' read -r id secret type domain created expires status comment; do
    if $first; then first=false; continue; fi  # Пропуск заголовка
    if [[ "$id" == "$secret_id" ]]; then
      # Меняем нужное поле
      case "$field" in
        id) id="$value" ;; secret) secret="$value" ;; type) type="$value" ;;
        domain) domain="$value" ;; created) created="$value" ;; expires) expires="$value" ;;
        status) status="$value" ;; comment) comment="$value" ;;
      esac
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$id" "$secret" "$type" "$domain" "$created" "$expires" "$status" "$comment" >> "$tmp"
  done < "${SECRETS_FILE}"

  chmod 600 "$tmp"
  mv -f "$tmp" "${SECRETS_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# secret_get_active — получить первый активный секрет (только значение)
# ─────────────────────────────────────────────────────────────────────────────
# Используется модулем docker.sh для запуска контейнера.
# Возвращает «сырой» секрет (hex-строку) без обёрток.
# ─────────────────────────────────────────────────────────────────────────────
secret_get_active() {
  _secrets_check || return 1
  active_secrets | head -1 | cut -d',' -f2
}

# ─────────────────────────────────────────────────────────────────────────────
# secret_get_all_active — получить все активные секреты
# ─────────────────────────────────────────────────────────────────────────────
# Возвращает список секретов (по одному на строку).
# Может использоваться для multi-secret режима прокси в будущем.
# ─────────────────────────────────────────────────────────────────────────────
secret_get_all_active() {
  _secrets_check || return 1
  active_secrets | cut -d',' -f2
}
