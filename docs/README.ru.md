<div align="center">

# ⚓ OpenShip Deploy

**Производственный инструментарий для установки [OpenShip](https://openship.io/) Control Plane**

[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![amd64 · arm64](https://img.shields.io/badge/arch-amd64%20·%20arm64-blue)](#требования)

[🇬🇧 English](../README.md) · [🇺🇦 Українська](README.ua.md)

</div>

---

## О проекте

**OpenShip Deploy** — интерактивный установщик для подготовки чистого VPS на Ubuntu 24.04 LTS под **OpenShip Control Plane** — лёгкий управляющий слой, который оркестрирует production-серверы, не обслуживая прикладной трафик напрямую.

---

## Архитектура

```text
                    Internet
                       │
                   Cloudflare
                       │
       ┌───────────────┴───────────────┐
       │                               │
 os.example.com                   app.example.com
       │                               │
  Control VPS                      Prod VPS
 Ubuntu 24.04, 1–2 GB           Ubuntu 24.04, 4–8 GB
       │                               │
 OpenShip Edge :80/:443         OpenShip Edge :80/:443
       │                               │
 OpenShip Bare :3001            Laravel / CRM
  (Control Plane daemon)        MariaDB + Redis
       │
       └────── SSH управление ─────────►
```

> [!IMPORTANT]
> **Ключевой принцип**: Control VPS **никогда не находится в HTTP-пути** production-приложений.
> Если Control VPS выключен, все production-приложения продолжают работать без перебоев.

---

## Режимы установки

| Режим | OpenShip Runtime | Прокси (:80/:443) | Docker | RAM | Назначение |
|---|---|---|---|---|---|
| **Bare** | Нативный процесс + встроенная БД | Edge контейнер | Только Edge | 1 GB | Выделенный Control Plane |
| **Standard** | Docker Compose | Edge контейнер | Полный стек | 2 GB | Полная Docker-среда |

---

## Установка

### Вариант A — одна команда (рекомендуется для чистого VPS)

```bash
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/install.sh | sudo bash
```

### Вариант B — клонирование

```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
chmod +x *.sh
sudo ./install.sh
```

Установщик **полностью интерактивен** — параметры командной строки не нужны.

---

## Что делает установщик

1. Проверяет Ubuntu 24.04 LTS и архитектуру
2. Проверяет CPU, RAM, диск — рекомендует Bare при < 2 GB RAM
3. Выбирает режим (Bare / Standard)
4. Собирает hostname, timezone, SSH-порт, имя администратора
5. Настраивает домен Control Plane и TLS через Edge (Let's Encrypt HTTP-01)
6. Настраивает **режим управления хостом** (терминал дашборда к этому VPS)
7. Устанавливает базовые пакеты, настраивает swap, journald, лимиты файлов
8. Создаёт администратора Linux, hardens SSH
9. Настраивает UFW и Fail2ban
10. Включает автоматические security updates
11. Устанавливает Docker (только Edge в Bare; полный стек в Standard)
12. Устанавливает OpenShip CLI
13. Запускает первичную настройку OpenShip (`--bare --non-interactive`)
14. Ожидает готовности API; при неудаче — автоматический rollback
15. Выводит сводку проверки после установки

---

## Режим управления хостом

| Вариант | Терминал дашборда | Сервер в OpenShip | Примечание |
|---|---|---|---|
| **Полный контроль** *(по умолчанию)* | ✅ Работает | ✅ Виден | Как v2.1.2 — рекомендуется |
| **Строгая изоляция** (`--no-host-control`) | ❌ Заблокирован | ❌ Скрыт | Максимальная изоляция |

---

## Настройка домена

| Вариант | Как работает |
|---|---|
| **Публичный HTTPS-домен** | OpenShip Edge (:80/:443) получает TLS через Let's Encrypt (HTTP-01). Направить DNS/Cloudflare A-запись на IP этого VPS. |
| **Локальный / приватный** | Дашборд остаётся на порту 3001. Только SSH открыт в UFW. Настроить Cloudflare Tunnel или VPN позже. |

---

## Службы баз данных для Worker-серверов

Для production/worker VPS — изолированный стек **MariaDB 11.4 + Redis 7.4**:

```bash
# На воркер-сервере
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
sudo ./deploy-services.sh
```

### Сеть проекта

```yaml
# docker-compose.yml проекта
networks:
  default:
    name: openship-network
    external: true
```

### Переменные окружения

```env
DB_HOST=mariadb
DB_PORT=3306
DB_CONNECTION=mysql
DB_DATABASE=your_project_db
DB_USERNAME=root
DB_PASSWORD=your_mariadb_root_password

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_CLIENT=phpredis
REDIS_PASSWORD=your_redis_password
```

### Управление стеком

```bash
sudo ./deploy-services.sh --status    # Статус
sudo ./deploy-services.sh --logs      # Логи
sudo ./deploy-services.sh --restart   # Перезапуск
sudo ./deploy-services.sh --pull      # Обновление образов
sudo ./deploy-services.sh --stop      # Остановка
```

### Бэкапы

```bash
cd services/mariadb-redis
sudo ./backup.sh          # Запустить бэкап
sudo ./backup.sh --list   # Список бэкапов
sudo ./backup.sh --cron   # Ежедневный cron в 03:00 UTC
```

---

## Обновление OpenShip

```bash
sudo ./update.sh --check   # Проверить обновление
sudo ./update.sh           # Применить
```

---

## Диагностика

```bash
sudo ./doctor.sh
```

Проверяет: ОС · архитектура · CPU/RAM/диск · swap · состояние установщика · OpenShip CLI · статус OpenShip · Node/Bun · Docker · порты · SSH · UFW · Fail2ban

---

## Логи и состояние

| Файл | Содержимое |
|---|---|
| `/var/log/openship-control-install.log` | Лог установки |
| `/var/log/openship-control-update.log` | Лог обновлений |
| `/var/log/openship-control-doctor.log` | Лог диагностики |
| `/etc/openship-control/install.conf` | Состояние установщика |

> [!NOTE]
> Пароль администратора OpenShip **не сохраняется** в state-файле.

---

## Требования

- **ОС**: Ubuntu 24.04 LTS
- **Доступ**: root или sudo
- **RAM**: минимум 768 MiB (Bare) · 2 GB+ рекомендуется (Standard)
- **Диск**: минимум 10 GB свободно
- **Архитектура**: amd64 или arm64

---

## Документация OpenShip

[openship.io/docs](https://openship.io/docs/)

---

## Лицензия

MIT
