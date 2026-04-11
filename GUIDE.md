# mtpx — Руководство пользователя

## Оглавление

1. [Быстрый старт](#быстрый-старт)
2. [Полный сценарий с нуля](#полный-сценарий-с-нуля)
3. [Управление пользователями](#управление-пользователями)
4. [Управление доменами](#управление-доменами)
5. [Частые задачи](#частые-задачи)
6. [Диагностика](#диагностика)
7. [Справочник команд](#справочник-команд)

---

## Быстрый старт

```bash
# 1. Установка
./install.sh

# 2. Создать домен
mtpx domain add ya.ru

# 3. Создать пользователя (контейнер создастся автоматически)
mtpx user add alice

# 4. Получить ссылки
mtpx user show alice
```

---

## Полный сценарий с нуля

### Шаг 1. Установка

```bash
cd /root/telegaproxy
bash install.sh
```

**Что делает:**
- Проверяет зависимости (docker, openssl, xxd, curl)
- Устанавливает Docker, если отсутствует
- Выставляет права на файлы
- Создаёт symlink `mtpx` в `~/.local/bin/`
- Инициализирует структуру проекта

### Шаг 2. Добавление доменов

Домены — это серверы, под которые прокси будет маскироваться.

```bash
mtpx domain add ya.ru
mtpx domain add google.com
mtpx domain add cloudflare.com
```

При добавлении домена создаются контейнеры для всех существующих пользователей. Если пользователей ещё нет — контейнеры не создаются (создадутся при добавлении пользователя).

### Шаг 3. Создание пользователей

Каждый пользователь получает **отдельный контейнер** для каждого домена.

```bash
mtpx user add alice
mtpx user add bob
```

**Что происходит:**
- Запись в `state/users.csv`
- Для **каждого существующего домена** создаётся контейнер `mtproto-<домен>-<username>` с уникальным секретом

### Шаг 4. Получение ссылок

```bash
# Все ссылки пользователя (все домены)
mtpx user show alice

# Только ссылка
mtpx user link alice

# Ссылка для конкретного домена
mtpx user link alice ya.ru
```

### Шаг 5. Раздача ссылок

Отправляете ссылку пользователю. Клик по ссылке `tg://proxy?...` в Telegram автоматически добавляет прокси.

---

## Управление пользователями

### Добавить пользователя

```bash
mtpx user add alice
```

Автоматически создаёт контейнеры для всех доменов.

### Посмотреть список

```bash
mtpx user list
```

### Карточка пользователя

```bash
mtpx user show alice

# Если IP авто-определён неверно (сервер за NAT)
mtpx user show alice 94.228.121.38
```

Показывает IP, Port, Secret для каждого домена + инструкцию по подключению.

### Отозвать доступ

```bash
# Временно (контейнеры удаляются)
mtpx user revoke alice

# Навсегда
mtpx user remove alice
```

### Перегенерировать секреты

```bash
mtpx user rotate alice
```

Отзывает старые секреты, создаёт новые контейнеры.

---

## Управление доменами

### Добавить домен

```bash
mtpx domain add duckduckgo.com
```

Создаёт контейнеры для всех пользователей.

### Удалить домен

```bash
mtpx domain remove ya.ru
```

Удаляет все контейнеры для домена и секреты.

### Список доменов

```bash
mtpx domain list
```

### Перезапустить / остановить / запустить

```bash
mtpx domain restart ya.ru
mtpx domain stop ya.ru
mtpx domain start ya.ru
```

### Логи

```bash
mtpx domain logs ya.ru
mtpx domain logs ya.ru 50   # последние 50 строк
```

---

## Частые задачи

### Добавить нового пользователя к существующим доменам

```bash
mtpx user add charlie
mtpx user show charlie
```

### Добавить новый домен для существующих пользователей

```bash
mtpx domain add duckduckgo.com
mtpx domain list
```

### Забрать доступ у пользователя

```bash
mtpx user revoke alice   # временно
mtpx user remove alice   # навсегда
```

### Начать с чистого листа

```bash
mtpx secrets clear
mtpx domain remove ya.ru
mtpx domain remove google.com
mtpx user add alice
mtpx domain add ya.ru
mtpx domain add google.com
```

### Обновить код на сервере

```bash
cd /root/telegaproxy
git pull
chmod +x mtpx
mtpx restart
```

---

## Диагностика

### Проверить состояние

```bash
mtpx status
```

### Полная диагностика

```bash
mtpx doctor
```

### Детали всех контейнеров

```bash
mtpx inspect
```

### Мониторинг

```bash
mtpx monitor
```

---

## Справочник команд

### Основные

| Команда | Описание |
|---------|----------|
| `mtpx init` | Инициализация |
| `mtpx apply` | Применить конфигурацию |
| `mtpx status` | Сводка |
| `mtpx doctor` | Диагностика |
| `mtpx inspect` | Детали контейнеров |
| `mtpx monitor` | Мониторинг |

### Домены

| Команда | Описание |
|---------|----------|
| `mtpx domain add <domain>` | Домен + контейнеры |
| `mtpx domain remove <domain>` | Удалить домен |
| `mtpx domain list` | Все домены |
| `mtpx domain links` | Все ссылки |
| `mtpx domain restart <domain>` | Перезапустить |
| `mtpx domain stop <domain>` | Остановить |
| `mtpx domain start <domain>` | Запустить |
| `mtpx domain logs <domain>` | Логи |

### Пользователи

| Команда | Описание |
|---------|----------|
| `mtpx user add <username>` | Создать |
| `mtpx user remove <username>` | Удалить |
| `mtpx user list` | Список |
| `mtpx user show <username> [ip]` | Карточка со ссылками |
| `mtpx user link <username> [domain]` | Ссылка |
| `mtpx user revoke <username>` | Отозвать |
| `mtpx user rotate <username>` | Перегенерировать |

### Операции

| Команда | Описание |
|---------|----------|
| `mtpx secrets clear` | Удалить все секреты |
| `mtpx stop` | Остановить все |
| `mtpx restart` | Перезапустить все |

---

## Архитектура

```
ya.ru + alice       → mtproto-ya-ru-alice       → SECRET=ee7961...
ya.ru + bob         → mtproto-ya-ru-bob         → SECRET=ee7962...
google.com + alice  → mtproto-google-com-alice  → SECRET=ee676f...
```

- **Образ:** telegrammessenger/proxy (официальный от Telegram)
- **Каждый пользователь** = отдельный контейнер на каждый домен
- **Мониторинг** — по контейнеру (просто и точно)
- **Изоляция** — можно удалить контейнер одного пользователя, не трогая других
