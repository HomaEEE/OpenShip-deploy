<div align="center">

# ⚓ OpenShip Deploy

**Виробничий інструментарій для встановлення [OpenShip](https://openship.io/) Control Plane**

[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![amd64 · arm64](https://img.shields.io/badge/arch-amd64%20·%20arm64-blue)](#вимоги)

[🇬🇧 English](../README.md) · [🇷🇺 Русский](README.ru.md)

</div>

---

## Про проєкт

**OpenShip Deploy** — інтерактивний інсталятор для підготовки чистого VPS на Ubuntu 24.04 LTS під **OpenShip Control Plane** — легкий управляючий шар, який оркеструє production-сервери, не обслуговуючи прикладний трафік напряму.

---

## Архітектура

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
       └────── SSH управління ─────────►
```

> [!IMPORTANT]
> **Ключовий принцип**: Control VPS **ніколи не знаходиться в HTTP-шляху** production-застосунків.
> Якщо Control VPS вимкнений, всі production-застосунки продовжують працювати без перерв.

---

## Режими встановлення

| Режим | OpenShip Runtime | Проксі (:80/:443) | Docker | RAM | Призначення |
|---|---|---|---|---|---|
| **Bare** | Нативний процес + вбудована БД | Edge контейнер | Тільки Edge | 1 GB | Виділений Control Plane |
| **Standard** | Docker Compose | Edge контейнер | Повний стек | 2 GB | Повна Docker-середа |

---

## Встановлення

### Варіант A — одна команда (рекомендується для чистого VPS)

```bash
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/install.sh | sudo bash
```

### Варіант B — клонування

```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
chmod +x *.sh
sudo ./install.sh
```

Інсталятор **повністю інтерактивний** — параметри командного рядка не потрібні.

---

## Що робить інсталятор

1. Перевіряє Ubuntu 24.04 LTS і архітектуру
2. Перевіряє CPU, RAM, диск — рекомендує Bare при < 2 GB RAM
3. Вибирає режим (Bare / Standard)
4. Збирає hostname, timezone, SSH-порт, ім'я адміністратора
5. Налаштовує домен Control Plane та TLS через Edge (Let's Encrypt HTTP-01)
6. Налаштовує **режим управління хостом** (термінал дашборду до цього VPS)
7. Встановлює базові пакети, налаштовує swap, journald, ліміти файлів
8. Створює адміністратора Linux, hardening SSH
9. Налаштовує UFW та Fail2ban
10. Вмикає автоматичні security updates
11. Встановлює Docker (тільки Edge у Bare; повний стек у Standard)
12. Встановлює OpenShip CLI
13. Запускає первинне налаштування OpenShip (`--bare --non-interactive`)
14. Очікує готовності API; при невдачі — автоматичний rollback
15. Виводить зведення перевірки після встановлення

---

## Режим управління хостом

| Варіант | Термінал дашборду | Сервер в OpenShip | Примітка |
|---|---|---|---|
| **Повний контроль** *(за замовч.)* | ✅ Працює | ✅ Видимий | Як v2.1.2 — рекомендується |
| **Сувора ізоляція** (`--no-host-control`) | ❌ Заблокований | ❌ Прихований | Максимальна ізоляція |

---

## Налаштування домену

| Варіант | Як працює |
|---|---|
| **Публічний HTTPS-домен** | OpenShip Edge (:80/:443) отримує TLS через Let's Encrypt (HTTP-01). Направити DNS/Cloudflare A-запис на IP цього VPS. |
| **Локальний / приватний** | Дашборд залишається на порту 3001. Тільки SSH відкритий у UFW. Налаштувати Cloudflare Tunnel або VPN пізніше. |

---

## Служби баз даних для Worker-серверів

Для production/worker VPS — ізольований стек **MariaDB 11.4 + Redis 7.4**:

```bash
# На воркер-сервері
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
sudo ./deploy-services.sh
```

### Мережа проєкту

```yaml
# docker-compose.yml проєкту
networks:
  default:
    name: openship-network
    external: true
```

### Змінні середовища

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

### Управління стеком

```bash
sudo ./deploy-services.sh --status    # Статус
sudo ./deploy-services.sh --logs      # Логи
sudo ./deploy-services.sh --restart   # Перезапуск
sudo ./deploy-services.sh --pull      # Оновлення образів
sudo ./deploy-services.sh --stop      # Зупинка
```

### Резервні копії

```bash
cd services/mariadb-redis
sudo ./backup.sh          # Запустити резервне копіювання
sudo ./backup.sh --list   # Список резервних копій
sudo ./backup.sh --cron   # Щоденний cron о 03:00 UTC
```

---

## Оновлення OpenShip

```bash
sudo ./update.sh --check   # Перевірити оновлення
sudo ./update.sh           # Застосувати
```

---

## Діагностика

```bash
sudo ./doctor.sh
```

Перевіряє: ОС · архітектура · CPU/RAM/диск · swap · стан інсталятора · OpenShip CLI · статус OpenShip · Node/Bun · Docker · порти · SSH · UFW · Fail2ban

---

## Логи та стан

| Файл | Вміст |
|---|---|
| `/var/log/openship-control-install.log` | Лог встановлення |
| `/var/log/openship-control-update.log` | Лог оновлень |
| `/var/log/openship-control-doctor.log` | Лог діагностики |
| `/etc/openship-control/install.conf` | Стан інсталятора |

> [!NOTE]
> Пароль адміністратора OpenShip **не зберігається** у state-файлі.

---

## Вимоги

- **ОС**: Ubuntu 24.04 LTS
- **Доступ**: root або sudo
- **RAM**: мінімум 768 MiB (Bare) · 2 GB+ рекомендується (Standard)
- **Диск**: мінімум 10 GB вільно
- **Архітектура**: amd64 або arm64

---

## Документація OpenShip

[openship.io/docs](https://openship.io/docs/)

---

## Ліцензія

MIT
