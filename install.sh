#!/usr/bin/env bash
###############################################################################
# install.sh — установщик mtpx
#
# Что делает:
#   1. Проверяет наличие внешних зависимостей (docker, openssl, xxd, curl)
#      — Если Docker не найден — автоматически устанавливает
#      — Если другие утилиты отсутствуют — предупреждает
#   2. Выставляет правильные права на файлы проекта:
#      • mtpx, start-mtproxy.sh, install.sh → 755 (исполняемые)
#      • lib/*.sh → 644 (чтение, без исполнения)
#   3. Создаёт symlink в ~/.local/bin/ для доступа из любого места
#   4. Запускает `mtpx init` для создания структуры проекта
#
# Автоматическая установка Docker поддерживается для:
#   • Debian/Ubuntu (apt)
#   • CentOS/RHEL (yum)
#   • Fedora (dnf)
#   • Alpine (apk)
#   • Arch Linux (pacman)
###############################################################################
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Настройки установки
# ─────────────────────────────────────────────────────────────────────────────
# INSTALL_DIR — директория для symlink. ~/.local/bin обычно уже в PATH
# на современных дистрибутивах. Если нет — installer подскажет.
INSTALL_DIR="${HOME}/.local/bin"

# SCRIPT_DIR — абсолютный путь к директории с установщиком
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Цвета (копируем из util.sh, т.к. installer автономен и не source-ит модули)
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${NC} $*" >&2; }
log_error() { echo -e "${RED}[✗]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}▸${NC} $*"; }

# Заголовок
echo "╔═════════════════════════════════════════════╗"
echo "║         mtpx installer                      ║"
echo "╚═════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Функции для определения пакетного менеджера
# ─────────────────────────────────────────────────────────────────────────────
# Определяем, какой менеджер пакетов доступен в системе.
# Возвращаем имя команды: apt, yum, dnf, apk, pacman.
# ─────────────────────────────────────────────────────────────────────────────
detect_package_manager() {
  if command -v apt-get &>/dev/null; then
    echo "apt"
  elif command -v dnf &>/dev/null; then
    echo "dnf"
  elif command -v yum &>/dev/null; then
    echo "yum"
  elif command -v apk &>/dev/null; then
    echo "apk"
  elif command -v pacman &>/dev/null; then
    echo "pacman"
  else
    echo ""
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# install_docker — автоматическая установка Docker
# ─────────────────────────────────────────────────────────────────────────────
# Определяет пакетный менеджер и запускает соответствующую процедуру установки.
# После установки:
#   • Запускает сервис Docker
#   • Включает автозапуск при загрузке (systemctl enable)
#   • Проверяет, что docker работает
#
# Для Debian/Ubuntu используем официальный скрипт с get.docker.com —
# это рекомендованный Docker-ом способ для быстрой установки.
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
  local pkg_mgr
  pkg_mgr="$(detect_package_manager)"

  if [[ -z "$pkg_mgr" ]]; then
    log_error "Не удалось определить пакетный менеджер"
    echo "  Установите Docker вручную: https://docs.docker.com/engine/install/"
    return 1
  fi

  log_step "Установка Docker (пакетный менеджер: ${pkg_mgr})..."
  echo ""

  # Проверяем, что у нас есть root или sudo
  local need_sudo=""
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo &>/dev/null; then
      need_sudo="sudo"
      log_step "Требуется sudo для установки Docker..."
      sudo -v || { log_error "sudo авторизация не удалась"; return 1; }
    else
      log_error "Запустите install.sh от root или установите sudo"
      return 1
    fi
  fi

  case "$pkg_mgr" in
    apt)
      install_docker_debian "$need_sudo"
      ;;
    dnf)
      install_docker_fedora "$need_sudo"
      ;;
    yum)
      install_docker_centos "$need_sudo"
      ;;
    apk)
      install_docker_alpine "$need_sudo"
      ;;
    pacman)
      install_docker_arch "$need_sudo"
      ;;
    *)
      log_error "Неподдерживаемый пакетный менеджер: $pkg_mgr"
      return 1
      ;;
  esac

  # Проверяем результат
  if command -v docker &>/dev/null; then
    log_info "Docker успешно установлен: $(docker --version)"
  else
    log_error "Docker не установлен после установки пакетов"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# install_docker_debian — установка Docker на Debian/Ubuntu
# ─────────────────────────────────────────────────────────────────────────────
# Метод 1: Официальный скрипт get.docker.com (рекомендуемый)
# Метод 2: Если curl недоступен — ставим docker.io из репозитория
# ─────────────────────────────────────────────────────────────────────────────
install_docker_debian() {
  local sudo_cmd="$1"
  echo "  📦 Debian/Ubuntu: установка Docker..."

  # Обновляем индексы пакетов
  echo "  ▸ Обновление списков пакетов..."
  $sudo_cmd apt-get update -y >/dev/null 2>&1 || true

  # Пробуем официальный скрипт Docker
  if command -v curl &>/dev/null; then
    echo "  ▸ Загрузка официального установщика Docker..."
    if $sudo_cmd curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
      echo "  ▸ Установка Docker через get.docker.com..."
      $sudo_cmd sh /tmp/get-docker.sh >/dev/null 2>&1
      rm -f /tmp/get-docker.sh
    else
      # Если скрипт недоступен — ставим из репозитория
      install_docker_from_repo "$sudo_cmd" "apt"
    fi
  else
    # Нет curl — ставим docker.io из репозитория
    install_docker_from_repo "$sudo_cmd" "apt"
  fi

  # Запускаем и включаем автозапуск
  $sudo_cmd systemctl enable docker >/dev/null 2>&1 || true
  $sudo_cmd systemctl start docker >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# install_docker_fedora — установка Docker на Fedora
# ─────────────────────────────────────────────────────────────────────────────
# Fedora использует dnf. Добавляем официальный репозиторий Docker CE.
# ─────────────────────────────────────────────────────────────────────────────
install_docker_fedora() {
  local sudo_cmd="$1"
  echo "  📦 Fedora: установка Docker CE..."

  # На Fedora обычно используют podman/docker из репозитория
  $sudo_cmd dnf install -y docker >/dev/null 2>&1 || {
    # Если нет в репозитории — добавляем Docker CE
    $sudo_cmd dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
    $sudo_cmd dnf install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1
  }

  $sudo_cmd systemctl enable docker >/dev/null 2>&1 || true
  $sudo_cmd systemctl start docker >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# install_docker_centos — установка Docker на CentOS/RHEL
# ─────────────────────────────────────────────────────────────────────────────
# Добавляем Docker CE репозиторий и ставим пакеты.
# ─────────────────────────────────────────────────────────────────────────────
install_docker_centos() {
  local sudo_cmd="$1"
  echo "  📦 CentOS/RHEL: установка Docker CE..."

  # Устанавливаем зависимости
  $sudo_cmd yum install -y yum-utils >/dev/null 2>&1 || true

  # Добавляем Docker CE репозиторий
  $sudo_cmd yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true

  # Устанавливаем Docker
  $sudo_cmd yum install -y docker-ce docker-ce-cli containerd.io >/dev/null 2>&1 || {
    # Fallback: docker из стандартного репозитория
    $sudo_cmd yum install -y docker >/dev/null 2>&1
  }

  $sudo_cmd systemctl enable docker >/dev/null 2>&1 || true
  $sudo_cmd systemctl start docker >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# install_docker_alpine — установка Docker на Alpine Linux
# ─────────────────────────────────────────────────────────────────────────────
# На Alpine Docker ставится из community-репозитория.
# ─────────────────────────────────────────────────────────────────────────────
install_docker_alpine() {
  local sudo_cmd="$1"
  echo "  📦 Alpine Linux: установка Docker..."

  $sudo_cmd apk update >/dev/null 2>&1 || true
  $sudo_cmd apk add --no-cache docker >/dev/null 2>&1

  $sudo_cmd rc-update add docker boot 2>/dev/null || true
  $sudo_cmd service docker start 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# install_docker_arch — установка Docker на Arch Linux
# ─────────────────────────────────────────────────────────────────────────────
# Docker есть в официальном репозитории Arch.
# ─────────────────────────────────────────────────────────────────────────────
install_docker_arch() {
  local sudo_cmd="$1"
  echo "  📦 Arch Linux: установка Docker..."

  $sudo_cmd pacman -Sy --noconfirm docker >/dev/null 2>&1 || true

  $sudo_cmd systemctl enable docker >/dev/null 2>&1 || true
  $sudo_cmd systemctl start docker >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# install_docker_from_repo — установка Docker из стандартного репозитория
# ─────────────────────────────────────────────────────────────────────────────
# Fallback-метод: если официальный скрипт недоступен, ставим docker.io
# из репозитория дистрибутива.
# ─────────────────────────────────────────────────────────────────────────────
install_docker_from_repo() {
  local sudo_cmd="$1"
  local pkg_mgr="$2"
  echo "  ▸ Установка docker.io из репозитория..."
  case "$pkg_mgr" in
    apt)
      $sudo_cmd apt-get install -y docker.io >/dev/null 2>&1
      ;;
    yum|dnf)
      $sudo_cmd "$pkg_mgr" install -y docker >/dev/null 2>&1
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 1: Проверка зависимостей
# ─────────────────────────────────────────────────────────────────────────────
# Проверяем ключевые команды:
#   • docker — если нет, предлагаем автоматическую установку
#   • openssl, xxd, curl — если нет, только предупреждаем
# ─────────────────────────────────────────────────────────────────────────────
log_step "Проверка зависимостей..."
echo ""

DOCKER_MISSING=false
OTHER_MISSING=0

# ── Docker ───────────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
  log_info "docker найден: $(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || 'ok')"
else
  log_warn "docker НЕ найден"
  DOCKER_MISSING=true
fi

# ── Остальные зависимости ───────────────────────────────────────────────────
for cmd in openssl xxd curl; do
  if command -v "$cmd" &>/dev/null; then
    log_info "$cmd найден"
  else
    log_warn "$cmd НЕ найден"
    OTHER_MISSING=$(( OTHER_MISSING + 1 ))
  fi
done

# ── Установка Docker, если отсутствует ───────────────────────────────────────
if $DOCKER_MISSING; then
  echo ""
  log_step "Docker не установлен — устанавливаем автоматически"
  echo ""
  if install_docker; then
    log_info "Docker установлен и запущен"
  else
    echo ""
    log_error "Не удалось установить Docker автоматически"
    echo "  Попробуйте установить вручную: https://docs.docker.com/engine/install/"
    echo ""
    echo "  После установки Docker запустите: bash $SCRIPT_DIR/install.sh"
    exit 1
  fi
fi

# Предупреждение о других зависимостях
if (( OTHER_MISSING > 0 )); then
  echo ""
  log_warn "Не найдено зависимостей: ${OTHER_MISSING} (не Docker)"
  echo "  Они могут потребоваться для работы mtpx"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 2: Права на файлы
# ─────────────────────────────────────────────────────────────────────────────
# Скрипты-Entrypoints (mtpx, start-mtproxy.sh, install.sh) — исполняемые (755).
# Библиотечные модули (lib/*.sh) — только чтение (644), т.к. они source-ятся,
# а не запускаются напрямую.
# ─────────────────────────────────────────────────────────────────────────────
log_step "Установка прав на файлы..."
chmod +x "${SCRIPT_DIR}/mtpx"
chmod +x "${SCRIPT_DIR}/start-mtproxy.sh"
chmod +x "${SCRIPT_DIR}/install.sh"
chmod 755 "${SCRIPT_DIR}/mtpx"
chmod 755 "${SCRIPT_DIR}/start-mtproxy.sh"

# lib/*.sh — 644 (rw-r--r--)
for f in "${SCRIPT_DIR}/lib/"*.sh; do
  chmod 644 "$f"
done
log_info "Права установлены"

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 3: Symlink в PATH
# ─────────────────────────────────────────────────────────────────────────────
# Создаём ~/.local/bin (если нет) и symlink на mtpx.
# Если symlink уже существует — перезаписываем (обновление).
# Проверяем, что INSTALL_DIR в PATH — если нет, подсказываем.
# ─────────────────────────────────────────────────────────────────────────────
log_step "Создание symlink..."
if [[ ! -d "${INSTALL_DIR}" ]]; then
  mkdir -p "${INSTALL_DIR}"
fi

# Проверяем: symlink или обычный файл с таким именем
if [[ -L "${INSTALL_DIR}/mtpx" ]] || [[ -f "${INSTALL_DIR}/mtpx" ]]; then
  log_warn "mtpx уже существует в ${INSTALL_DIR}, обновляем..."
  rm -f "${INSTALL_DIR}/mtpx"
fi

# ln -sf — force перезаписать существующий symlink
ln -sf "${SCRIPT_DIR}/mtpx" "${INSTALL_DIR}/mtpx"
log_info "Symlink создан: ${INSTALL_DIR}/mtpx -> ${SCRIPT_DIR}/mtpx"

# Проверяем, есть ли INSTALL_DIR в PATH
# :${PATH}: — оборачиваем, чтобы найти :/home/user/.local/bin: даже в начале/конце
if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  log_warn "${INSTALL_DIR} не в PATH"
  echo "  Добавьте в ~/.bashrc или ~/.zshrc:"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
else
  log_info "${INSTALL_DIR} уже в PATH"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 4: Инициализация проекта
# ─────────────────────────────────────────────────────────────────────────────
# Запускаем `mtpx init` через bash, чтобы создать config/ и state/.
# Это гарантирует, что после установки пользователь может сразу начать работу.
# ─────────────────────────────────────────────────────────────────────────────
log_step "Инициализация..."
bash "${SCRIPT_DIR}/mtpx" init

# ─────────────────────────────────────────────────────────────────────────────
# Финальное сообщение
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔═════════════════════════════════════════════╗"
echo "║         Установка завершена!                ║"
echo "╚═════════════════════════════════════════════╝"
echo ""
echo "  Быстрый старт:"
echo "    mtpx secret add"
echo "    mtpx apply"
echo "    mtpx status"
echo ""
echo "  Справка: mtpx help"
echo ""
