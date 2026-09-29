# OpenShip — Shared Services (MariaDB + Redis)

Репозиторий для развертывания общих сервисов баз данных (**MariaDB 11.4 LTS** и **Redis 7.4 Alpine**) в платформе **OpenShip** с закрытым доступом через единую сеть Docker (`openship-network`).

Никаких посторонних сервисов — только база данных и кэш/очереди для ваших проектов.

---

## 🏗 Архитектура

```
                     [ Internet ]
                          │
                   (OpenShip Edge)
                          │ :80 / :443
               ┌──────────┴──────────┐
               │  Проекты (Noire...) │
               │     FrankenPHP      │
               └──────────┬──────────┘
                          │ Docker Network (openship-network)
         ┌────────────────┴────────────────┐
         │                                 │
  [ MariaDB:3306 ]                  [ Redis:6379 ]
  • Изолирован от интернета         • Изолирован от интернета
  • Named Volume: mariadb_data      • Named Volume: redis_data
  • UTF-8mb4 / InnoDB Tuned         • LRU Eviction / AOF
  • Автосоздание БД проектами       • Префиксы ключей по проектам
```

---

## 🚀 Развертывание в OpenShip

1. Подключите этот репозиторий в панели **OpenShip**.
2. OpenShip автоматически обнаружит корневой `docker-compose.yml` и `openship.json`.
3. Задайте Environment Variables (при необходимости):

| Переменная | Дефолт | Описание |
|---|---|---|
| `MARIADB_ROOT_PASSWORD` | `openship_root_secret` | Root-пароль MariaDB |
| `MARIADB_BUFFER_POOL_SIZE` | `512M` | Размер буферного пула InnoDB |
| `MARIADB_LOG_FILE_SIZE` | `128M` | Размер Redo-лога InnoDB |
| `MARIADB_MAX_CONNECTIONS` | `150` | Лимит соединений |
| `MARIADB_MEMORY_LIMIT` | `1536M` | Ограничение RAM контейнера MariaDB |
| `REDIS_PASSWORD` | *(пусто)* | Пароль Redis (для внутренней сети опционален) |
| `REDIS_MAXMEMORY` | `256mb` | Лимит оперативной памяти Redis |
| `REDIS_MEMORY_LIMIT` | `512M` | Ограничение RAM контейнера Redis |

4. Нажмите **Deploy**. Сервисы запустятся в общей сети `openship-network` со встроенными healthcheck-проверками.

---

## 🔒 Сеть и безопасность

- Порты `3306` и `6379` **не выставлены наружу** на хост и не доступны из публичного интернета.
- Доступ возможен **только** из контейнеров, подключенных к `openship-network`.
- MariaDB и Redis доступны по постоянным DNS-алиасам:
  - `mariadb:3306`
  - `redis:6379`

---

## 📦 Подключение проектов (Noire и др.)

Для развертывания ваших Laravel-проектов используйте готовый универсальный шаблон:
👉 [`templates/laravel-frankenphp/`](templates/laravel-frankenphp/)

Каждый проект при первом запуске:
1. Автоматически находит MariaDB и Redis в сети.
2. Подключается с `DB_ROOT_PASSWORD` и **сам создает свою базу данных и пользователя** с нужным паролем.
3. Удаляет root-пароль из памяти.
4. Накатывает миграции и запускает FrankenPHP на порту 80.

---

## 💾 Автоматический бэкап баз данных

Скрипт [`backup.sh`](backup.sh) делает сжатый дамп всех баз данных с ротацией 7 дней:

```bash
# Ручной запуск
sudo /usr/local/bin/mariadb-backup.sh

# Cron (ежедневно в 03:00 UTC)
0 3 * * * /usr/local/bin/mariadb-backup.sh >> /var/log/mariadb-backup.log 2>&1
```

Дампы сохраняются в `/var/backups/mariadb/`.
