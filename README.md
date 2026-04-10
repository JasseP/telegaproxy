# mtpx — MTProto Proxy (v3: multi-user, multi-domain)

CLI-утилита для управления MTProto Proxy с поддержкой **нескольких доменов** и **нескольких пользователей**.

## Архитектура

Каждый домен = отдельный контейнер (alexbers/mtprotoproxy).
Каждый пользователь = уникальный секрет для каждого домена.

```
ya.ru       → mtproto-ya-ru       → alice=ee7961..., bob=ee7962...
google.com  → mtproto-google-com  → alice=ee676f..., bob=ee6770...
```

## Быстрый старт

```bash
./install.sh

# Или вручную:
./mtpx init
./mtpx domain add ya.ru
./mtpx domain add google.com
./mtpx user add alice
./mtpx user add bob
./mtpx user link alice      # все ссылки alice
./mtpx user link bob ya.ru  # ссылка bob для ya.ru
```

## Команды

### Основные

| Команда | Описание |
|---------|----------|
| `mtpx init` | Инициализация |
| `mtpx apply [domain]` | Запустить все (или один) |
| `mtpx status` | Сводка |
| `mtpx doctor` | Диагностика |
| `mtpx inspect [domain]` | Детали контейнера |

### Домены

| Команда | Описание |
|---------|----------|
| `mtpx domain add <domain>` | Домен + контейнер + секреты для всех пользователей |
| `mtpx domain remove <domain>` | Удалить домен + контейнер |
| `mtpx domain list` | Все домены |
| `mtpx domain links` | Все ссылки |
| `mtpx domain restart <domain>` | Перезапустить |
| `mtpx domain stop/start <domain>` | Остановить/запустить |
| `mtpx domain logs <domain>` | Логи |

### Пользователи

| Команда | Описание |
|---------|----------|
| `mtpx user add <username>` | Создать + секреты для всех доменов |
| `mtpx user remove <username>` | Удалить + все секреты |
| `mtpx user list` | Список |
| `mtpx user link <username> [domain]` | Ссылка (все домены или конкретный) |
| `mtpx user revoke <username>` | Отозвать секреты |
| `mtpx user rotate <username>` | Перегенерировать секреты |

### Операции

| Команда | Описание |
|---------|----------|
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
│   ├── domains.txt         — список доменов
│   └── proxy-*.py          — конфиги прокси (авто)
├── state/
│   ├── users.csv           — пользователи
│   └── secrets.csv         — секреты (user+domain)
│   └── runtime.env         — runtime
└── lib/
    ├── util.sh
    ├── config.sh
    ├── config_proxy.sh     # Генерация Python-конфигов
    ├── secret.sh
    ├── domain.sh
    ├── docker.sh           # alexbers/mtprotoproxy
    ├── user.sh             # CRUD пользователей
    ├── monitor.sh
    └── status.sh
```

## Зависимости

- `docker`
- `openssl`, `xxd`, `curl`
- `ss` или `netstat`

## Лицензия

MIT
