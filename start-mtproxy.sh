#!/bin/bash
###############################################################################
# start-mtproxy.sh — обёртка для быстрой инициализации и запуска MTProxy v4
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
MTPX="${SCRIPT_DIR}/mtpx"

if [[ ! -f "${MTPX}" ]]; then
  echo "❌ Не найден mtpx CLI: ${MTPX}"
  exit 1
fi

echo "🚀 Запуск MTProto прокси (v4: multi-user)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Инициализация
bash "${MTPX}" init 2>/dev/null || true

# Если нет доменов — создаём первый
DOMAIN_COUNT=$(bash "${MTPX}" domain list 2>/dev/null | grep -c 'mtproto-' || echo "0")
if [[ "$DOMAIN_COUNT" -eq 0 ]]; then
  echo "📌 Нет доменов — создаю '${DEFAULT_DOMAIN:-ya.ru}'..."
  bash "${MTPX}" domain add "${DEFAULT_DOMAIN:-ya.ru}"
  echo ""
fi

# Запускаем
echo "📦 Запуск..."
echo ""
bash "${MTPX}" status

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "👤 Пользователи:"
bash "${MTPX}" user list 2>/dev/null || echo "  Нет пользователей"
echo ""
echo "💡 Создать пользователя: mtpx user add <name>"
echo "💡 Получить ссылки:    mtpx user show <name>"
echo ""
