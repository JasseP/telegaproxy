# mtpx — CLI для управления MTProto Proxy (v2: multi-proxy)

CLI-утилита для развёртывания и управления [MTProto Proxy](https://github.com/TelegramMessenger/MTProxy) с поддержкой **нескольких доменов** — каждый домен = отдельный контейнер со своим секретом.

## Архитектура

```
ya.ru       → mtproto-ya-ru       → SECRET=ee79612e7275...
google.com  → mtproto-google-com  → SECRET=ee676f6f676c...
cloud.com   → mtproto-cloud-com   → SECRET=ee636c6f7564...
```

Каждый пользователь получает свою ссылку для каждого домена и выбирает сам, через какой подключаться.

## Быстрый старт

```bash
# Установка
./install.sh

# Или вручную
chmod +x mtpx
./mtpx init
./mtpx domain add ya.ru
./mtpx domain add google.com
./mtpx apply
```

## Команды

### Основные

| Команда | Описание |
|---------|----------|
| `mtpx init` | Инициализация проекта |
| `mtpx apply [domain]` | Запустить все домены (или один конкретный) |
| `mtpx status` | Сводка состояния |
| `mtpx doctor` | Диагностика зависимостей и состояния |
| `mtpx inspect [domain]` | Детали контейнера (все или конкретный) |

### Домены (каждый = контейнер)

| Команда | Описание |
|---------|----------|
| `mtpx domain add <domain>` | Создать домен + контейнер + секрет |
| `mtpx domain remove <domain>` | Удалить домен + контейнер + секреты |
| `mtpx domain list` | Все домены с их статусом |
| `mtpx domain link <domain>` | Ссылка tg:// для конкретного домена |
| `mtpx domain links` | Все ссылки для всех доменов |
| `mtpx domain restart <domain>` | Перезапустить контейнер домена |
| `mtpx domain stop <domain>` | Остановить контейнер домена |
| `mtpx domain start <domain>` | Запустить контейнер домена |
| `mtpx domain logs <domain> [n]` | Логи контейнера домена |

### Операции

| Команда | Описание |
|---------|----------|
| `mtpx stop` | Остановить все прокси |
| `mtpx restart` | Перезапустить все прокси |
| `mtpx monitor` | Эвристический мониторинг |

## Обновление на сервере

```bash
# Игнорировать изменения прав (install.sh делает chmod)
git config core.fileMode false

# Обновить код
git pull
```

## Архитектура файлов

```
telegaProxy/
├── mtpx                    # CLI entrypoint
├── start-mtproxy.sh        # Обратная совместимость (обёртка)
├── install.sh              # Установка
├── config/
│   └── domains.txt         — список доменов (один на строку)
├── state/
│   ├── secrets.csv         — секреты (привязаны к домену)
│   └── runtime.env         — runtime параметры
└── lib/
    ├── util.sh             # Утилиты (логирование, валидация, atomic write)
    ├── config.sh           # Управление конфигами
    ├── secret.sh           # Управление секретами + domain helpers
    ├── domain.sh           # Домены (add/remove/list/link)
    ├── docker.sh           # Docker-операции (per-domain containers)
    ├── monitor.sh          # Эвристический мониторинг
    └── status.sh           # Сводный статус
```

## Формат секретов

CSV: `id,secret,type,domain,created_at,expires_at,status,comment`

Типы:
- **fake_tls** — Fake TLS секрет (префикс `ee` + hex домена + random)
- **simple** — Простой 16-байтный hex
- **secure** — Fake TLS (алиас)

Статусы: `active`, `revoked`, `expired`

## Безопасность

- Файлы секретов: `chmod 600`
- Атомарная запись через temp file + mv
- Секреты не печатаются полностью без явного флага
- `state/` содержит чувствительные данные
- Git `core.fileMode=false` — защита от ложных конфликтов

## Обратная совместимость

`start-mtproxy.sh` работает как раньше, но теперь использует `mtpx` внутри:

```bash
# Старый способ (работает)
bash start-mtproxy.sh

# Новый способ
./mtpx domain add ya.ru
./mtpx domain add google.com
./mtpx apply
```

## Зависимости

- `docker`
- `openssl`
- `xxd` (из vim/vim-common)
- `curl`
- `ss` или `netstat`

## Лицензия

MIT
