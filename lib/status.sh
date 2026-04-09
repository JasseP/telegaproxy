#!/usr/bin/env bash
###############################################################################
# lib/status.sh — сводный статус всей системы MTProxy
#
# Собирает информацию из ВСЕХ модулей и представляет её в компактном
# или развёрнутом виде. В отличие от monitor.sh, этот модуль показывает
# КОНФИГУРАЦИЮ (какие секреты, домены, настройки), а не ТЕКУЩЕЕ СОСТОЯНИЕ
# (работает/не работает, ошибки, соединения).
#
# Два режима вывода:
#   status_full    — развёрнутая таблица (основной режим)
#   status_compact — одна строка (для скриптов, быстрого просмотра)
###############################################################################
set -euo pipefail

# Подключаем все модули — статусу нужна полная картина
# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${MTPX_ROOT}/lib/config.sh"
# shellcheck source=lib/secret.sh
source "${MTPX_ROOT}/lib/secret.sh"
# shellcheck source=lib/docker.sh
source "${MTPX_ROOT}/lib/docker.sh"
# shellcheck source=lib/monitor.sh
source "${MTPX_ROOT}/lib/monitor.sh"
# shellcheck source=lib/domain.sh
source "${MTPX_ROOT}/lib/domain.sh"

# ─────────────────────────────────────────────────────────────────────────────
# status_full — развёрнутый статус
# ─────────────────────────────────────────────────────────────────────────────
# Выводит таблицу с:
#   • Состояние контейнера (running / stopped / не создан)
#   • Порт
#   • Текущий домен
#   • Количество активных секретов
#   • Статус авто-ротации
#
# Каждый блок защищён: если данные недоступны (файл не создан, команда
# не доступна), выводим "N/A" или заглушку вместо падения с ошибкой.
# ─────────────────────────────────────────────────────────────────────────────
status_full() {
  echo ""
  echo "╔═════════════════════════════════════════════╗"
  echo "║         MTProxy Status                      ║"
  echo "╠═════════════════════════════════════════════╣"
  echo "║"

  # ── Контейнер ────────────────────────────────────────────────────────────
  # container_status возвращает: running, stopped, none
  local cstatus
  cstatus=$(container_status)
  case "$cstatus" in
    running)
      echo "║  🟢 Контейнер:     running"
      ;;
    stopped)
      echo "║  🟡 Контейнер:     stopped"
      ;;
    none)
      echo "║  🔴 Контейнер:     не создан"
      ;;
  esac

  # ── Порт ─────────────────────────────────────────────────────────────────
  # Берём из runtime.env, fallback на DEFAULT_PORT
  local port
  port=$(runtime_get "PORT")
  port="${port:-$DEFAULT_PORT}"
  echo "║  🔌 Порт:            ${port}"

  # ── Домен ────────────────────────────────────────────────────────────────
  # domain_current может упасть, если domains.txt не существует — ловим
  local domain
  domain=$(domain_current 2>/dev/null || echo "N/A")
  echo "║  🌐 Домен:           ${domain}"

  # ── Секреты ──────────────────────────────────────────────────────────────
  # Показываем соотношение активных к общему количеству
  local total active_count
  total=$(secret_count 2>/dev/null || echo "0")
  active_count=$(active_secrets 2>/dev/null | wc -l)
  echo "║  🔑 Секреты:         ${active_count}/${total} активных"

  # ── Авто-ротация ─────────────────────────────────────────────────────────
  # Проверяем, включена ли авто-ротация и какой интервал
  local auto_enabled
  auto_enabled=$(auto_get "AUTO_ENABLED" 2>/dev/null || echo "false")
  if [[ "$auto_enabled" == "true" ]]; then
    local interval
    interval=$(auto_get "AUTO_INTERVAL")
    echo "║  🔄 Авто-ротация:    вкл (${interval}с)"
  else
    echo "║  🔄 Авто-ротация:    выкл"
  fi

  echo "║"
  echo "╚═════════════════════════════════════════════╝"
}

# ─────────────────────────────────────────────────────────────────────────────
# status_compact — однострочный статус
# ─────────────────────────────────────────────────────────────────────────────
# Формат:
#   <icon> container=<state> port=<port> domain=<domain> secrets=<count>
#
# Иконка: 🟢 running, 🟡 stopped, 🔴 не создан
#
# Зачем? Для быстрого просмотра, cron-отчётов, интеграции с другими
# инструментами (например, отправка в Telegram-бота).
# ─────────────────────────────────────────────────────────────────────────────
status_compact() {
  local cstatus
  cstatus=$(container_status)
  local port
  port=$(runtime_get "PORT")
  port="${port:-$DEFAULT_PORT}"
  local domain
  domain=$(domain_current 2>/dev/null || echo "N/A")
  local active_count
  active_count=$(active_secrets 2>/dev/null | wc -l)

  # Выбираем иконку по статусу
  local icon
  case "$cstatus" in
    running) icon="🟢" ;;
    stopped) icon="🟡" ;;
    none)    icon="🔴" ;;
  esac

  printf '%s container=%s port=%s domain=%s secrets=%d\n' \
    "$icon" "$cstatus" "$port" "$domain" "$active_count"
}
