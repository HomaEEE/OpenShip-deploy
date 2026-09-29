# Laravel + FrankenPHP Deployment Template for OpenShip

Шаблон для быстрого развертывания любого Laravel-проекта в OpenShip с автоматическим созданием базы данных в MariaDB и подключением к Redis.

---

## ⚡ Особенности шаблона

1. **Автоматическое создание БД и пользователя**:
   При первом запуске контейнера `entrypoint.sh` через PHP PDO подключается к MariaDB с `DB_ROOT_PASSWORD` (по умолчанию `openship_root_secret`), создает базу данных `DB_DATABASE`, пользователя `DB_USERNAME`, задает пароль `DB_PASSWORD` и выдает все права. После создания пароль root удаляется из окружения.
2. **Автопоиск хостов MariaDB & Redis**:
   Автоматически определяет имя хоста (`mariadb`, `openship-openship-deploy-mariadb`, `redis`, `openship-openship-deploy-redis`), исключая ошибки DNS Docker.
3. **FrankenPHP + Caddy**:
   Высокопроизводительный сервер на порту 80 с поддержкой Cloudflare trusted proxies.
4. **Изоляция очередей и кэша**:
   Префиксы `CACHE_PREFIX` и `REDIS_PREFIX` предотвращают конфликты ключей между проектами в общем Redis.

---

## 📁 Структура шаблона

```
project/
├── .github/
│   └── workflows/
│       └── deploy.yml          # GitHub Actions сборка в GHCR + вызов вебхука OpenShip
├── deploy/
│   ├── Caddyfile              # Конфигурация веб-сервера FrankenPHP
│   ├── Dockerfile             # PHP 8.4 + расширения + Composer
│   ├── docker-compose.yml     # Compose-файл для OpenShip
│   ├── entrypoint.sh          # Скрипт автоподключения, создания БД и запуска
│   └── php.ini                # Настройки OPcache и лимитов
├── openship.json              # Дескриптор сервиса OpenShip
└── README.md
```

---

## 🚀 Как применить к новому проекту

### Шаг 1. Скопировать файлы в проект
Скопируйте папки `deploy/`, `.github/` и файл `openship.json` в корень вашего Laravel-репозитория.

### Шаг 2. Переменные окружения в OpenShip

В панели OpenShip добавьте Environment Variables:

| Переменная | Пример | Описание |
|---|---|---|
| `APP_NAME` | `MyProject` | Имя приложения |
| `APP_ENV` | `production` | Окружение |
| `APP_KEY` | `base64:...` | Ключ шифрования Laravel |
| `APP_URL` | `https://myproject.com` | Домен проекта |
| `DB_DATABASE` | `myproject` | Имя базы данных |
| `DB_USERNAME` | `myproject` | Пользователь базы данных |
| `DB_PASSWORD` | `strong_pass_123` | Пароль пользователя БД |
| `DB_ROOT_PASSWORD` | `openship_root_secret` | Пароль root (по умолчанию совпадает с общим MariaDB) |
| `APP_SLUG` | `myproject` | Префикс для Redis и тома storage |
| `IMAGE_NAME` | `ghcr.io/org/myproject` | Образ из GHCR |
| `IMAGE_TAG` | `latest` | Тег образа |

### Шаг 3. Деплой
1. Запушьте код в GitHub — GitHub Action соберет образ и запушит в GHCR.
2. В OpenShip нажмите **Deploy**.
3. При старте контейнер сам создаст БД, накатит миграции и запустит веб-сервер.
