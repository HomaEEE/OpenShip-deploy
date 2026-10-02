# OpenShip Worker VPS Tuning

Скрипт оптимизации Ubuntu 24.04 / 22.04 LTS под высокие нагрузки, OpenShip Edge и FrankenPHP (низкий TTFB, HTTP/3, тюнинг сокетов и памяти).

> **Примечание:** Установка Docker намеренно не выполняется — скрипт готовит ОС, ядро, сеть, лимиты и фаервол.

---

## Быстрый запуск

### В 1 команду (удаленный сервер):
```bash
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/services/server-tuning/tune.sh | sudo bash
```

### Из локального репозитория:
```bash
sudo ./services/server-tuning/tune.sh
```

### Неинтерактивно / Проверка:
```bash
sudo ./services/server-tuning/tune.sh --non-interactive
./services/server-tuning/tune.sh --dry-run
```

---

## Что настраивает скрипт

1. **FrankenPHP & Низкий TTFB (`/etc/sysctl.d/99-openship-worker.conf`)**:
   - `tcp_fastopen = 3` (минус 1 RTT на хэндшейк), `tcp_slow_start_after_idle = 0` (нет троттлинга keep-alive).
   - TCP BBR (`default_qdisc = fq`, `tcp_congestion_control = bbr`).
   - Быстрый оборот портов: `tcp_tw_reuse = 1`, `tcp_fin_timeout = 15`, диапазон портов `1024 65535`.
   - 16MB сетевые сокет-буферы + UDP буферы под HTTP/3 QUIC (`rmem_default = 262144`).
   - Сброс грязных страниц без I/O фризов: `vm.dirty_ratio = 15`, `vm.dirty_background_ratio = 5`.
   - Память под MariaDB и Redis: `vm.overcommit_memory = 1`, `vm.max_map_count = 262144`.
2. **CPU Governor**:
   - Перевод процессора в режим `performance` (устранение задержек масштабирования частоты, персистентно через systemd).
3. **Лимиты и логи**:
   - `nofile 65535` и `nproc 65535` для root и всех пользователей (`/etc/security/limits.d/99-openship-worker.conf`).
   - Ограничение systemd journald до 200MB.
4. **Swap**:
   - Автоматический swapfile (2GB при RAM ≤ 2GB, 4GB при RAM > 2GB) с `vm.swappiness = 10`.
5. **Безопасность (UFW & Fail2ban)**:
   - Открыты порты: SSH (дефолт 22), `80/tcp` (HTTP), `443/tcp` и `443/udp` (HTTP/3 QUIC).
   - Базы данных закрыты от внешнего мира. Fail2ban для SSH.

---

## Параметры запуска

| Флаг | Описание |
|---|---|
| `--non-interactive` | Применить настройки без диалоговых окон (из `.env` или дефолты) |
| `--dry-run` | Проверить совместимость и параметры без изменения системы |
| `--ssh-port=PORT` | Указать кастомный SSH-порт (дефолт `22`) |
| `--swap-size=GB` | Указать размер swapfile в гигабайтах |
| `--admin-user=USER` | Создать отдельного sudo-администратора |
| `--skip-packages` | Пропустить `apt update / upgrade` |
| `--skip-swap` | Пропустить настройку swap |
| `--skip-sysctl` | Пропустить тюнинг ядра и sysctl |
| `--skip-ufw` | Пропустить настройку фаервола UFW |
| `--skip-ssh` | Пропустить перенастройку SSH |
| `--help` | Справка |
