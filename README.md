# mtpx — MTProto Proxy (v4: один контейнер = один пользователь)

CLI-утилита для управления MTProto Proxy. Каждый пользователь получает **отдельный контейнер** для каждого домена.

## Архитектура

```
ya.ru + alice       → mtproto-ya-ru-alice       → SECRET=ee7961...
ya.ru + bob         → mtproto-ya-ru-bob         → SECRET=ee7962...
google.com + alice  → mtproto-google-com-alice  → SECRET=ee676f...
```

Каждый контейнер — отдельный процесс с одним секретом. Мониторинг, перезапуск и управление — на уровне контейнера.

## Быстрый старт

```bash
./install.sh

# Или вручную
chmod +x mtpx
./mtpx init
./mtpx domain add ya.ru
./mtpx user add alice
./mtpx user show alice      # все ссылки alice
```

## Команды

### Основные

| Команда | Описание |
|---------|----------|
| `mtpx init` | Инициализация |
| `mtpx apply` | Применить конфигурацию |
| `mtpx status` | Сводка состояния |
| `mtpx doctor` | Диагностика |
| `mtpx inspect` | Детали всех контейнеров |

### Домены

| Команда | Описание |
|---------|----------|
| `mtpx domain add <domain>` | Домен + контейнеры для всех пользователей |
| `mtpx domain remove <domain>` | Удалить домен + контейнеры |
| `mtpx domain list` | Все домены |
| `mtpx domain links` | Все ссылки |
| `mtpx domain restart/stop/start <domain>` | Управление контейнерами домена |
| `mtpx domain logs <domain>` | Логи |

### Пользователи

| Команда | Описание |
|---------|----------|
| `mtpx user add <username>` | Создать пользователя + контейнеры для всех доменов |
| `mtpx user remove <username>` | Удалить пользователя + контейнеры |
| `mtpx user list` | Список |
| `mtpx user show <username> [ip]` | Карточка со ссылками и инструкцией |
| `mtpx user link <username> [domain]` | Ссылка (все или конкретный домен) |
| `mtpx user revoke <username>` | Отозвать |
| `mtpx user rotate <username>` | Перегенерировать |

### Операции

| Команда | Описание |
|---------|----------|
| `mtpx secrets clear` | Удалить все секреты |
| `mtpx stop` | Остановить все |
| `mtpx restart` | Перезапустить все |
| `mtpx monitor` | Мониторинг |

## Обновление на сервере

```bash
git config core.fileMode false
git pull
```

## Структура

```
telegaProxy/
├── mtpx                    # CLI entrypoint
├── start-mtproxy.sh        # Обёртка
├── install.sh              # Установка
├── config/
│   └── domains.txt         — список доменов
├── state/
│   ├── users.csv           — пользователи
│   ├── secrets.csv         — секреты (domain+username)
│   └── runtime.env         — runtime
└── lib/
    ├── util.sh
    ├── config.sh
    ├── secret.sh
    ├── domain.sh
    ├── docker.sh           # telegrammessenger/proxy
    ├── user.sh
    ├── monitor.sh
    └── status.sh
```

## Зависимости

- `docker`
- `openssl`, `xxd`, `curl`
- `ss` или `netstat`

## Лицензия

MIT
