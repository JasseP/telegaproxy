# mtpx — CLI для управления MTProto Proxy

CLI-утилита для развёртывания и управления [MTProto Proxy](https://github.com/TelegramMessenger/MTProxy) с поддержкой Fake TLS, ротации доменов и эвристического мониторинга.

## Быстрый старт

```bash
# Установка
./install.sh

# Или вручную
chmod +x mtpx
./mtpx init
./mtpx secret add
./mtpx apply
```

## Команды

### Основные

| Команда | Описание |
|---------|----------|
| `mtpx init` | Инициализация проекта (создаёт config/ и state/) |
| `mtpx apply [port]` | Применить конфигурацию и запустить прокси |
| `mtpx status` | Сводка состояния |
| `mtpx doctor` | Диагностика зависимостей и состояния |
| `mtpx inspect` | Детальная информация о контейнере |

### Домены

| Команда | Описание |
|---------|----------|
| `mtpx domain current` | Текущий домен |
| `mtpx domain list` | Все домены |
| `mtpx domain add <domain>` | Добавить домен |
| `mtpx domain set <domain>` | Установить текущий домен |
| `mtpx domain remove <domain>` | Удалить домен |
| `mtpx domain rotate` | Ротировать домен |
| `mtpx domain auto enable [interval]` | Включить авто-ротацию |
| `mtpx domain auto disable` | Выключить авто-ротацию |
| `mtpx domain auto status` | Статус авто-ротации |
| `mtpx domain auto tick` | Проверить/выполнить авто-ротацию |

### Секреты

| Команда | Описание |
|---------|----------|
| `mtpx secret add [type] [domain]` | Добавить секрет (fake_tls/simple/secure) |
| `mtpx secret list [status]` | Список (active/revoked) |
| `mtpx secret show [--reveal] <id>` | Показать секрет |
| `mtpx secret revoke <id>` | Отозвать |
| `mtpx secret rotate <id> [type]` | Ротировать |
| `mtpx secret delete <id>` | Удалить |
| `mtpx secret link [id] [server] [port]` | Ссылка tg:// |

### Операции

| Команда | Описание |
|---------|----------|
| `mtpx logs [n]` | Последние n строк логов |
| `mtpx restart` | Перезапустить контейнер |
| `mtpx stop` | Остановить контейнер |
| `mtpx monitor` | Эвристический мониторинг |

## Архитектура

```
telegaProxy/
├── mtpx                    # CLI entrypoint
├── start-mtproxy.sh        # Обратная совместимость (обёртка)
├── install.sh              # Установка
├── config/
│   └── domains.txt         # Список доменов (текущий первый)
├── state/
│   ├── secrets.csv         # Секреты (CSV: id,secret,type,domain,...)
│   ├── runtime.env         # Runtime параметры (PORT, LAST_APPLY)
│   └── auto_tick.env       # Настройки авто-ротации
└── lib/
    ├── util.sh             # Утилиты (логирование, валидация, атомарная запись)
    ├── config.sh           # Управление конфигами
    ├── secret.sh           # Управление секретами
    ├── domain.sh           # Управление доменами + auto tick
    ├── docker.sh           # Docker-операции
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
- Секреты не печатаются полностью без `--reveal`
- `state/` содержит чувствительные данные

## Обратная совместимость

`start-mtproxy.sh` работает как раньше, но теперь использует `mtpx` внутри:

```bash
# Старый способ (работает)
bash start-mtproxy.sh

# Новый способ
./mtpx init && ./mtpx secret add && ./mtpx apply
```

## Зависимости

- `docker`
- `openssl`
- `xxd` (из vim/vim-common)
- `curl`
- `ss` или `netstat`

## Лицензия

MIT
