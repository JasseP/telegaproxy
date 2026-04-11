#!/usr/bin/env bash
###############################################################################
# lib/docker.sh — управление Docker-контейнерами MTProxy (v4: один контейнер = один пользователь)
#
# Архитектура:
#   Каждый пользователь получает отдельный контейнер для каждого домена.
#   Имя контейнера: mtproto-<normalized_domain>-<username>
#   Примеры:
#     ya.ru + alice       → mtproto-ya-ru-alice
#     ya.ru + bob         → mtproto-ya-ru-bob
#     google.com + alice  → mtproto-google-com-alice
#
# Образ: telegrammessenger/proxy (официальный от Telegram)
# Каждый контейнер принимает ОДИН секрет через переменную SECRET.
###############################################################################
set -euo pipefail

# shellcheck source=lib/util.sh
source "${MTPX_ROOT}/lib/util.sh"
# shellcheck source=lib/config.sh
source "${MTPX_ROOT}/lib/config.sh"
# shellcheck source=lib/secret.sh
source "${MTPX_ROOT}/lib/secret.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Образ прокси
# ─────────────────────────────────────────────────────────────────────────────
MT_PROXY_IMAGE="telegrammessenger/proxy"

# ─────────────────────────────────────────────────────────────────────────────
# Имя контейнера: mtproto-<domain>-<username>
# ─────────────────────────────────────────────────────────────────────────────
container_name_for() {
  local domain="$1"
  local username="$2"
  local norm
  norm=$(normalize_domain "$domain")
  printf 'mtproto-%s-%s' "$norm" "$username"
}

# ─────────────────────────────────────────────────────────────────────────────
# Проверка состояния контейнера
# ─────────────────────────────────────────────────────────────────────────────
docker_container_exists() {
  local cname="$1"
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qxF "$cname"
}

docker_container_running() {
  local cname="$1"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qxF "$cname"
}

docker_container_status() {
  local cname="$1"
  if docker_container_running "$cname"; then
    echo "running"
  elif docker_container_exists "$cname"; then
    echo "stopped"
  else
    echo "none"
  fi
}

docker_container_port() {
  local cname="$1"
  if ! docker_container_running "$cname"; then
    echo "-"
    return
  fi
  local port_info
  port_info=$(docker port "$cname" 2>/dev/null || echo "")
  if [[ -n "$port_info" ]]; then
    echo "$port_info" | head -1 | grep -oE '[0-9]+$' || echo "-"
  else
    echo "-"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Операции с контейнерами
# ─────────────────────────────────────────────────────────────────────────────
docker_stop_container() {
  local cname="$1"
  if docker_container_running "$cname"; then
    docker stop "$cname" >/dev/null 2>&1 || true
  fi
}

docker_remove_container() {
  local cname="$1"
  docker_stop_container "$cname"
  if docker_container_exists "$cname"; then
    docker rm "$cname" >/dev/null 2>&1 || true
  fi
}

docker_restart_container() {
  local cname="$1"
  if ! docker_container_running "$cname"; then
    log_error "Контейнер ${cname} не запущен"
    return 1
  fi
  log_step "Перезапуск ${cname}..."
  docker restart "$cname" >/dev/null 2>&1
  log_ok
}

docker_container_logs() {
  local cname="$1"
  local lines="${2:-20}"
  if ! docker_container_exists "$cname"; then
    log_error "Контейнер ${cname} не найден"
    return 1
  fi
  docker logs --tail "$lines" "$cname" 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# docker_start_container — запустить контейнер для пользователя на домене
# ─────────────────────────────────────────────────────────────────────────────
# docker_start_container <domain> <username> <secret> [port]
#
# Запускает официальный контейнер telegrammessenger/proxy с одним секретом.
# ─────────────────────────────────────────────────────────────────────────────
docker_start_container() {
  local domain="$1"
  local username="$2"
  local secret="$3"
  local port="${4:-}"

  local cname
  cname=$(container_name_for "$domain" "$username")

  # Определяем порт
  if [[ -z "$port" ]]; then
    port=$(find_free_port 443 8443 8444 8445 8446 8447 8448 8449 8450) || {
      log_error "Нет свободных портов для ${cname}"
      return 1
    }
  fi

  # Удаляем старый контейнер, если есть
  if docker_container_exists "$cname"; then
    docker_remove_container "$cname"
  fi

  log_step "Запуск ${cname}..."
  echo "  Образ:   ${MT_PROXY_IMAGE}"
  echo "  Домен:   ${domain}"
  echo "  User:    ${username}"
  echo "  Порт:    ${port}:443"
  echo "  Secret:  $(mask_secret "$secret")"

  if docker run -d \
    --name "$cname" \
    --restart unless-stopped \
    -p "${port}:443" \
    -e SECRET="${secret}" \
    "${MT_PROXY_IMAGE}" >/dev/null 2>&1; then

    sleep 2

    if docker_container_running "$cname"; then
      runtime_set "LAST_APPLY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      log_info "Контейнер ${cname} запущен"
      return 0
    else
      log_error "Контейнер ${cname} не запустился"
      docker logs "$cname" 2>&1 || true
      return 1
    fi
  else
    log_error "Ошибка при запуске контейнера ${cname}"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# docker_sync_user_domain — создать/обновить контейнер для пользователя на домене
# ─────────────────────────────────────────────────────────────────────────────
# Если контейнер есть и запущен — перезапускает (чтобы подхватить новый секрет).
# Если контейнер stopped — пересоздаёт.
# Если контейнера нет — создаёт.
# ─────────────────────────────────────────────────────────────────────────────
docker_sync_user_domain() {
  local domain="$1"
  local username="$2"
  local secret="$3"

  local cname
  cname=$(container_name_for "$domain" "$username")
  local cstatus
  cstatus=$(docker_container_status "$cname")

  case "$cstatus" in
    running)
      # Пересоздаём с новым секретом
      docker_remove_container "$cname"
      docker_start_container "$domain" "$username" "$secret"
      ;;
    stopped)
      docker_remove_container "$cname"
      docker_start_container "$domain" "$username" "$secret"
      ;;
    none)
      docker_start_container "$domain" "$username" "$secret"
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# docker_remove_user_domain — удалить контейнер пользователя для домена
# ─────────────────────────────────────────────────────────────────────────────
docker_remove_user_domain() {
  local domain="$1"
  local username="$2"
  local cname
  cname=$(container_name_for "$domain" "$username")
  docker_remove_container "$cname"
}

# ─────────────────────────────────────────────────────────────────────────────
# docker_remove_all_for_domain — удалить все контейнеры для домена
# ─────────────────────────────────────────────────────────────────────────────
docker_remove_all_for_domain() {
  local domain="$1"
  local norm
  norm=$(normalize_domain "$domain")
  local prefix="mtproto-${norm}-"

  docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^${prefix}" | while IFS= read -r cname; do
    docker_remove_container "$cname"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# docker_remove_all_for_user — удалить все контейнеры пользователя
# ─────────────────────────────────────────────────────────────────────────────
docker_remove_all_for_user() {
  local username="$1"
  local suffix="-${username}"

  docker ps -a --format '{{.Names}}' 2>/dev/null | grep "${suffix}$" | while IFS= read -r cname; do
    docker_remove_container "$cname"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Статистика
# ─────────────────────────────────────────────────────────────────────────────
count_running_proxies() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -c '^mtproto-' || echo "0"
}

count_all_proxies() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -c '^mtproto-' || echo "0"
}

# ─────────────────────────────────────────────────────────────────────────────
# Операции со всеми контейнерами
# ─────────────────────────────────────────────────────────────────────────────
stop_all() {
  local count=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep '^mtproto-' | while IFS= read -r cname; do
    docker_stop_container "$cname"
    count=$(( count + 1 ))
  done
  log_info "Контейнеры остановлены"
}

restart_all() {
  local count=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep '^mtproto-' | while IFS= read -r cname; do
    docker restart "$cname" >/dev/null 2>&1
    count=$(( count + 1 ))
  done
  log_info "Перезапущено контейнеров: ${count}"
}
