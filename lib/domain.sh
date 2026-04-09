#!/usr/bin/env bash
###############################################################################
# lib/domain.sh — управление доменами: ротация, авто-ротация, tick
#
# Зачем ротировать домены?
#   Fake TLS маскирует трафик MTProxy под HTTPS-соединение с указанным
#   доменом. Если домен «засветился» (провайдер/ DPI начал блокировать
#   TLS-соединения с этим доменом), смена домена позволяет обойти блокировку.
#
# Авто-ротация:
#   По таймеру (интервал в секундах) первый домен перемещается в конец
#   списка, и следующий домен становится активным. Для применения нового
#   домена нужен `mtpx apply` (перезапуск прокси с новым секретом).
#
# Хранение настроек: state/auto_tick.env
#   AUTO_ENABLED    — true/false
#   AUTO_INTERVAL   — интервал в секундах (по умолчанию 3600 = 1 час)
#   AUTO_LAST_ROTATE — epoch последнего срабатывания
#   AUTO_NEXT_ROTATE — epoch следующего срабатывания
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${MTPX_ROOT}/lib/config.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Auto tick — конфигурация
# ─────────────────────────────────────────────────────────────────────────────
AUTO_TICK_FILE="${STATE_DIR}/auto_tick.env"

# ── auto_init — инициализация файла авто-ротации ─────────────────────────────
# Создаём auto_tick.env с настройками по умолчанию.
# AUTO_ENABLED=false — авто-ротация выключена до явного включения.
# ─────────────────────────────────────────────────────────────────────────────
auto_init() {
  if [[ ! -f "${AUTO_TICK_FILE}" ]]; then
    cat > "${AUTO_TICK_FILE}" <<EOF
AUTO_ENABLED=false
AUTO_INTERVAL=3600
AUTO_LAST_ROTATE=0
AUTO_NEXT_ROTATE=0
EOF
    chmod 600 "${AUTO_TICK_FILE}"
    log_info "Создан ${AUTO_TICK_FILE}"
  fi
}

# ── auto_get / auto_set — чтение/запись настроек авто-ротации ────────────────
# Обёртки над env_get / env_set из util.sh.
# ─────────────────────────────────────────────────────────────────────────────
auto_get() {
  env_get "${AUTO_TICK_FILE}" "$1"
}

auto_set() {
  env_set "${AUTO_TICK_FILE}" "$1" "$2"
}

# ─────────────────────────────────────────────────────────────────────────────
# auto_enable — включить автоматическую ротацию
# ─────────────────────────────────────────────────────────────────────────────
# auto_enable [interval]
#
# interval — период ротации в секундах (по умолчанию 3600 = 1 час).
# Рассчитываем AUTO_NEXT_ROTATE = now + interval.
# После включения auto_tick начнёт ротировать домен при каждом вызове,
# если текущее время >= AUTO_NEXT_ROTATE.
# ─────────────────────────────────────────────────────────────────────────────
auto_enable() {
  local interval="${1:-3600}"

  auto_init

  local now
  now=$(date +%s)
  auto_set "AUTO_ENABLED" "true"
  auto_set "AUTO_INTERVAL" "$interval"
  auto_set "AUTO_LAST_ROTATE" "$now"
  auto_set "AUTO_NEXT_ROTATE" "$(( now + interval ))"

  log_info "Автоматическая ротация включена (интервал: ${interval}с)"
}

# ─────────────────────────────────────────────────────────────────────────────
# auto_disable — выключить автоматическую ротацию
# ─────────────────────────────────────────────────────────────────────────────
# Просто ставим AUTO_ENABLED=false. Таймеры сохраняются — при повторном
# включении можно продолжить с того же места.
# ─────────────────────────────────────────────────────────────────────────────
auto_disable() {
  auto_init
  auto_set "AUTO_ENABLED" "false"
  log_info "Автоматическая ротация выключена"
}

# ─────────────────────────────────────────────────────────────────────────────
# auto_should_rotate — проверить, пора ли ротировать
# ─────────────────────────────────────────────────────────────────────────────
# Возвращает 0 (true), если:
#   • AUTO_ENABLED == true
#   • Текущее время >= AUTO_NEXT_ROTATE
# Иначе — 1 (false).
# ─────────────────────────────────────────────────────────────────────────────
auto_should_rotate() {
  auto_init
  local enabled
  enabled=$(auto_get "AUTO_ENABLED")
  if [[ "$enabled" != "true" ]]; then
    return 1  # Авто-ротация выключена
  fi

  local now next
  now=$(date +%s)
  next=$(auto_get "AUTO_NEXT_ROTATE")
  next="${next:-0}"

  if (( now >= next )); then
    return 0  # Пора ротировать
  else
    return 1  # Ещё рано
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# auto_tick — проверить и выполнить авто-ротацию
# ─────────────────────────────────────────────────────────────────────────────
# Вызывается периодически (например, из cron или systemd timer).
#
# Если ещё не пора — выводит время до следующей ротации.
# Если пора:
#   1. Перемещает первый домен в конец списка
#   2. Обновляет таймер (LAST_ROTATE = now, NEXT_ROTATE = now + interval)
#   3. Напоминает, что нужен `mtpx apply` для применения
#
# Важно: tick НЕ перезапускает прокси автоматически. Это сделано намеренно —
# пользователь сам решает, когда применить изменения.
# ─────────────────────────────────────────────────────────────────────────────
auto_tick() {
  # Если ещё не пора — выводим информацию и выходим
  if ! auto_should_rotate; then
    local next
    next=$(auto_get "AUTO_NEXT_ROTATE")
    if [[ -n "$next" ]] && (( next > 0 )); then
      local remaining=$(( next - $(date +%s) ))
      if (( remaining > 0 )); then
        echo "  Авто-ротация: следующее выполнение через ${remaining}с"
      else
        echo "  Авто-ротация: ожидает активации"
      fi
    else
      echo "  Авто-ротация: не настроена"
    fi
    return 0
  fi

  log_step "⏰ Авто-ротация домена..."

  local current
  current=$(domain_current)
  log_info "Текущий домен: ${current}"

  # Проверяем, достаточно ли доменов для ротации
  local domains
  domains=$(domain_list)
  local total
  total=$(echo "$domains" | wc -l)

  if (( total < 2 )); then
    log_warn "Только один домен в списке. Добавьте ещё: mtpx domain add <domain>"
    # Обновляем таймер, чтобы не спамить ротацией
    local now interval
    now=$(date +%s)
    interval=$(auto_get "AUTO_INTERVAL")
    auto_set "AUTO_LAST_ROTATE" "$now"
    auto_set "AUTO_NEXT_ROTATE" "$(( now + interval ))"
    return 0
  fi

  # Перемещаем первый домен в конец списка
  local tmp
  tmp="$(mktemp "${DOMAINS_FILE}.tmp.XXXXXX")"
  tail -n +2 "${DOMAINS_FILE}" > "$tmp"  # Все, кроме первого
  head -1 "${DOMAINS_FILE}" >> "$tmp"    # Первый — в конец
  mv -f "$tmp" "${DOMAINS_FILE}"

  local new_domain
  new_domain=$(domain_current)
  log_info "Новый домен: ${new_domain}"

  # Обновляем таймер
  local now interval
  now=$(date +%s)
  interval=$(auto_get "AUTO_INTERVAL")
  auto_set "AUTO_LAST_ROTATE" "$now"
  auto_set "AUTO_NEXT_ROTATE" "$(( now + interval ))"

  log_info "Домен ротирован: ${current} → ${new_domain}"
  echo "  Не забудьте: mtpx apply  (для перезапуска прокси с новым доменом)"
}

# ─────────────────────────────────────────────────────────────────────────────
# domain_rotate — ручная ротация домена
# ─────────────────────────────────────────────────────────────────────────────
# Перемещает первый домен в конец списка.
# Требует минимум 2 домена в списке (иначе ротация бессмысленна).
# ─────────────────────────────────────────────────────────────────────────────
domain_rotate() {
  local current
  current=$(domain_current)
  local domains
  domains=$(domain_list)
  local total
  total=$(echo "$domains" | wc -l)

  if (( total < 2 )); then
    log_error "Нужно минимум 2 домена для ротации. Сейчас: ${total}"
    log_info "Добавьте домен: mtpx domain add <domain>"
    return 1
  fi

  # Атомарно перемещаем первый домен в конец
  local tmp
  tmp="$(mktemp "${DOMAINS_FILE}.tmp.XXXXXX")"
  tail -n +2 "${DOMAINS_FILE}" > "$tmp"  # Со второго до конца
  head -1 "${DOMAINS_FILE}" >> "$tmp"    # Первый — в конец
  mv -f "$tmp" "${DOMAINS_FILE}"

  local new_domain
  new_domain=$(domain_current)
  log_info "Домен ротирован: ${current} → ${new_domain}"
}

# ─────────────────────────────────────────────────────────────────────────────
# auto_status — статус авто-ротации
# ─────────────────────────────────────────────────────────────────────────────
# Выводит таблицу:
#   • Включена / выключена
#   • Интервал
#   • Время до следующей ротации (или "готова к запуску")
# ─────────────────────────────────────────────────────────────────────────────
auto_status() {
  auto_init
  local enabled interval last next

  enabled=$(auto_get "AUTO_ENABLED")
  interval=$(auto_get "AUTO_INTERVAL")
  last=$(auto_get "AUTO_LAST_ROTATE")
  next=$(auto_get "AUTO_NEXT_ROTATE")

  echo "┌─────────────────────────────────────────┐"
  echo "│  Авто-ротация доменов                   │"
  echo "├─────────────────────────────────────────┤"
  if [[ "$enabled" == "true" ]]; then
    echo "│  Статус:        ВКЛ                     │"
    echo "│  Интервал:      ${interval}с"
    if [[ -n "$next" ]] && (( next > 0 )); then
      local remaining=$(( next - $(date +%s) ))
      if (( remaining > 0 )); then
        printf "│  Следующая:   через %-6dс            │\n" "$remaining"
      else
        echo "│  Следующая:   ГОТОВА К ЗАПУСКУ       │"
      fi
    else
      echo "│  Следующая:     не назначена           │"
    fi
  else
    echo "│  Статус:        ВЫКЛ                    │"
  fi
  echo "└─────────────────────────────────────────┘"
}
