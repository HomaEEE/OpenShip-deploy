<div align="center">

# ⚓ OpenShip Deploy

**Автоматизированный инструментарий для развертывания Control Plane и сервисов [OpenShip](https://openship.io/) на Ubuntu 24.04 LTS**

[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![amd64 · arm64](https://img.shields.io/badge/arch-amd64%20·%20arm64-blue)](#требования)
[![License MIT](https://img.shields.io/badge/license-MIT-green)](#лицензия)

| [🇬🇧 English](../README.md) | 🇷🇺 **Русский** | [🇺🇦 Українська](README.ua.md) |
| :---: | :---: | :---: |

</div>

---

## Быстрый старт

### 1. Установка Control Plane
Полная подготовка чистого VPS на Ubuntu 24.04 LTS (безопасность, swap, UFW, Caddy, OpenShip):

```bash
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/install.sh | sudo bash
```

Или через клонирование репозитория:
```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy && chmod +x *.sh
sudo ./install.sh
```

### 2. Диагностика системы и OpenShip (`doctor.sh`)
Быстрая проверка состояния Control Plane, реверс-прокси Caddy, внутренних портов и файрвола:

```bash
# Прямой запуск через curl (без клонирования)
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/doctor.sh | sudo bash

# Или локально из папки репозитория
sudo ./doctor.sh
```

---

## Архитектура

```text
                    Интернет
                       │
                   Cloudflare
                       │
       ┌───────────────┴───────────────┐
       │                               │
 os.example.com                   apps.example.com
       │                               │
  Control VPS                      Worker VPS
 Ubuntu 24.04 (1–2 ГБ)            Ubuntu 24.04 (4–8 ГБ)
       │                               │
  Caddy :80/:443                  OpenShip Edge :80/:443
   ├── :3001 (UI Дашборда)             │
   └── :4000 (API и WebSockets)    Laravel (FrankenPHP)
       │                               │ (openship-openship-deploy)
       │                        ┌──────┴──────┐
       │                        │             │
       │                   MariaDB:3306  Redis:6379
       │
       └────── SSH управление ─────────►
```

> [!IMPORTANT]
> **Главный инвариант**: Control VPS **никогда не участвует в обработке пользовательского HTTP-трафика** рабочих приложений. Если Control VPS временно недоступен, все прод-приложения продолжают работать без сбоев.

---

## Режимы Control Plane

| Режим | Стек OpenShip | Прокси | Мин. RAM | Рекомендация |
|---|---|---|---|---|
| **Bare** *(Рекомендуется)* | Нативный процесс + встроенная БД | Caddy reverse proxy | 1 ГБ | Выделенный Control VPS (быстро, легковесно) |
| **Standard** | Docker Compose стек | OpenShip Edge контейнер | 2 ГБ | Полная изоляция в Docker |

### Реверс-прокси Caddy (в режиме Bare)
Caddy принимает внешний трафик и безопасно проксирует его локально:
- `handle_path /api/proxy/*` → `127.0.0.1:4000` (API OpenShip и WebSockets терминала)
- `handle /api/*` → `127.0.0.1:4000` (прямые вызовы API)
- `handle` → `127.0.0.1:3001` (UI дашборда)
- Порты `3001` и `4000` закрыты в UFW от внешнего прямого доступа.

---

## Диагностика (`doctor.sh`)

Скрипт [`doctor.sh`](../doctor.sh) проводит полную проверку здоровья хоста и компонентов OpenShip.

### Запуск

```bash
# Одной командой через curl
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/doctor.sh | sudo bash

# Локально
sudo ./doctor.sh
```

### Что проверяет скрипт

| Категория | Что проверяется |
|---|---|
| **Ресурсы хоста** | Версия OS, ядро, ядра CPU, оперативная память, Swap, свободный диск |
| **Control Plane** | Наличие CLI, версия, активность systemd-юнита (`openship.service`) |
| **Caddy Прокси** | Статус сервиса Caddy, маршрутизация Caddyfile (`:3001` и `:4000`) |
| **Порты** | Состояние `ss -lntp` для SSH, дашборда (`:3001`) и API (`:4000`) |
| **Docker и сокет** | Демон Docker, доступность `/var/run/docker.sock` для управления хостом |
| **Файрвол (UFW)** | Открыты `:80`, `:443`, SSH; порты `:3001` и `:4000` надежно закрыты |
| **Безопасность** | Активность Fail2ban и джейла SSH |

*Логи проверки автоматически сохраняются в `/var/log/openship-doctor.log`.*

---

## Базы данных Worker (MariaDB + Redis)

Для серверов с рабочими приложениями:

### Деплой через интерфейс OpenShip
Добавьте этот репозиторий в дашборд OpenShip. Файл `docker-compose.yml` в корне запустит **MariaDB 11.4 LTS + Redis 7.4 Alpine** в сеть `openship-openship-deploy`. Порты наружу не публикуются.

### Управление через CLI
```bash
sudo ./deploy-services.sh             # Запуск стека
sudo ./deploy-services.sh --status    # Статус контейнеров
sudo ./deploy-services.sh --logs      # Просмотр логов
sudo ./deploy-services.sh --restart   # Перезапуск стека
sudo ./deploy-services.sh --stop      # Остановка (данные сохраняются)
```

### Автоматический бэкап
```bash
sudo ./backup.sh                      # Мгновенный бэкап MariaDB в gzip
# Ежедневный бэкап в 03:00 UTC (хранение 7 дней в /var/backups/mariadb/):
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/mariadb-backup.sh >> /var/log/mariadb-backup.log 2>&1") | crontab -
```

---

## Шаблоны приложений

В директории [`templates/laravel-frankenphp/`](../templates/laravel-frankenphp/) доступен готовый шаблон для Laravel:
- Сервер FrankenPHP на Caddy с поддержкой HTTP/3 и worker-режима.
- Автообнаружение MariaDB и Redis во внутренней сети Docker.
- Автоматическое создание базы данных и пользователя при первом старте.
- Автоматический запуск миграций (`migrate --force`) и кэширование конфигурации.

---

## Обновление OpenShip

```bash
sudo ./update.sh --check   # Проверить наличие обновлений
sudo ./update.sh           # Применить обновление
```

---

## Структура репозитория

```text
OpenShip-deploy/
├── install.sh                  # Автоматический инсталлятор Control Plane
├── doctor.sh                   # Диагностика системы и сервисов OpenShip
├── update.sh                   # Скрипт обновления OpenShip
├── deploy-services.sh          # Управление стеком MariaDB + Redis
├── backup.sh                   # Скрипт резервного копирования баз данных
├── docker-compose.yml          # Compose-файл баз данных для деплоя из OpenShip
├── openship.json               # Манифест OpenShip
├── templates/
│   └── laravel-frankenphp/     # Шаблон для деплоя Laravel + FrankenPHP
└── docs/
    ├── README.ru.md            # Документация на русском
    └── README.ua.md            # Документація українською
```

---

## Требования

- **ОС**: Ubuntu 24.04 LTS (amd64 / arm64)
- **Права**: root или sudo
- **Control VPS**: от 1 ГБ RAM (в режиме Bare), 10 ГБ диска
- **Worker VPS**: от 2–8 ГБ RAM (под нагрузку приложений)

---

## Лицензия

MIT
