#!/bin/bash
###############################################################################
# start-mtproxy.sh — обёртка для быстрой инициализации и запуска MTProxy v2
#
# Обратная совместимость: запускает прокси через mtpx CLI.
# Автоматически инициализирует, создаёт первый домен (ya.ru) если нет доменов,
# и запускает все контейнеры.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MTPX="${SCRIPT_DIR}/mtpx"

if [[ ! -f "${MTPX}" ]]; then
  echo "❌ Не найден mtpx CLI: ${MTPX}"
  echo "   Убедитесь, что файлы проекта на месте."
  exit 1
fi

echo "🚀 Запуск MTProto прокси (v2: multi-proxy)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Инициализация (если ещё не инициализировано)
bash "${MTPX}" init 2>/dev/null || true

# Если нет доменов — создаём первый по умолчанию
DOMAIN_COUNT=$(bash "${MTPX}" domain list 2>/dev/null | grep -c 'mtproto-' || echo "0")
if [[ "$DOMAIN_COUNT" -eq 0 ]]; then
  echo "📌 Нет доменов — создаю '${DEFAULT_DOMAIN:-ya.ru}'..."
  bash "${MTPX}" domain add "${DEFAULT_DOMAIN:-ya.ru}"
  echo ""
fi

# Запускаем все домены
echo "📦 Запуск прокси..."
echo ""
bash "${MTPX}" apply

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔗 Ссылки для подключения:"
bash "${MTPX}" domain links
echo ""
echo "💡 Полный контроль: ./mtpx help"
