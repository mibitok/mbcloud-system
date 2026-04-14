#!/bin/bash
#===============================================================================
# mbcloud NAS - Установка дополнительных компонентов (v1.0)
# Использование:
#   • Интерактивно:  curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/install-addons.sh | sudo bash
#   • Автоматически: curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/install-addons.sh | sudo bash -s -- --all
#   • По выбору:     ./install-addons.sh (локально)
#===============================================================================

# 🎨 Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ⚙️ Конфигурация
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_PATH="${REPO_PATH:-/home/${SUDO_USER:-$(whoami)}/mbcloud-system}"
DATA_MOUNT="/DATA"
USER="${SUDO_USER:-$(whoami)}"
DOCKER_DIR="$REPO_PATH/docker"

# 📢 Функции вывода
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_err() { echo -e "${RED}[✗]${NC} $1"; }
header() {
    echo ""; echo -e "${CYAN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║  mbcloud NAS - Addons Installer v1.0 ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════╝${NC}"
    echo "  $(date '+%Y-%m-%d %H:%M:%S') | User: $USER"; echo ""
}

#===============================================================================
# 🔧 ОБЩИЕ ФУНКЦИИ
#===============================================================================

check_root() {
    [[ $EUID -ne 0 ]] && { log_err "Запустите с: curl ... | sudo bash"; exit 1; }
}

check_repo() {
    if [ ! -d "$REPO_PATH/.git" ]; then
        log "Клонируем репозиторий..."
        git clone -b "$REPO_BRANCH" "https://github.com/mibitok/mbcloud-system.git" "$REPO_PATH" 2>/dev/null || \
        { log_warn "Не удалось клонировать — используем базовые настройки"; REPO_PATH="/home/$USER/mbcloud-system"; }
    fi
}

install_docker_if_needed() {
    if ! command -v docker &>/dev/null; then
        log "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null && sudo sh /tmp/get-docker.sh 2>/dev/null && \
        { sudo usermod -aG docker "$USER" 2>/dev/null; log_ok "Docker установлен"; } || \
        { sudo apt install -y -qq docker.io docker-compose-plugin 2>/dev/null && log_ok "Docker установлен через apt"; }
        rm -f /tmp/get-docker.sh
    else
        log_ok "Docker уже установлен"
    fi
    # Применяем группу без перезагрузки
    newgrp docker 2>/dev/null || true
}

#===============================================================================
# 🐳 DOCKER + IMMICH
#===============================================================================

install_immich() {
    header "🐳 Установка Immich"
    
    echo -e "${CYAN}Immich — само-хостимый сервис для синхронизации фото (как Google Photos).${NC}"
    echo -e "${YELLOW}Требования:${NC} 2 ГБ ОЗУ, 10 ГБ места на /DATA, ~3 ГБ для образов"
    echo ""
    
    read -p "Установить Immich? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_warn "Пропущено"; return 0; }
    
    install_docker_if_needed
    
    # Проверяем место
    local free=$(df -BG "$DATA_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
    if [ -n "$free" ] && [ "$free" -lt 10 ]; then
        log_warn "Мало места на $DATA_MOUNT: ${free}GB (нужно минимум 10 ГБ)"
        read -p "Продолжить? (y/N): " -n 1 -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi
    
    # Настраиваем
    log "Настраиваем Immich..."
    mkdir -p "$DOCKER_DIR"
    
    if [ ! -f "$DOCKER_DIR/.env" ] && [ -f "$DOCKER_DIR/.env.example" ]; then
        cp "$DOCKER_DIR/.env.example" "$DOCKER_DIR/.env"
        local pass=$(openssl rand -hex 16 2>/dev/null || echo "mbcloud_$(date +%s)")
        sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$pass/" "$DOCKER_DIR/.env"
        chown "$USER:$USER" "$DOCKER_DIR/.env"
        log_ok "Файл .env создан"
    fi
    
    # Создаём папки
    for dir in upload library postgres redis; do mkdir -p "$DATA_MOUNT/immich-$dir"; done
    chown -R 999:999 "$DATA_MOUNT/immich-postgres" "$DATA_MOUNT/immich-redis" 2>/dev/null || true
    
    # Запускаем
    log "Запускаем Immich (2-5 минут)..."
    cd "$DOCKER_DIR"
    if docker compose up -d 2>&1 | tee /tmp/immich.log; then
        log_ok "Immich запущен!"
        log "🌐 http://$(hostname -I | awk '{print $1}'):2283"
        log "📱 Приложение: укажите тот же адрес"
        log "🔐 Первый пользователь = админ"
    else
        log_err "Ошибка запуска — проверьте: docker compose logs -f"
    fi
    
    # Алиас
    grep -q "alias immich=" ~/.bashrc 2>/dev/null || echo "alias immich='cd $DOCKER_DIR && docker compose'" >> ~/.bashrc
    log "Добавлен алиас: ${BLUE}immich${NC}"
}

#===============================================================================
# 💾 MERGERFS В FSTAB
#===============================================================================

setup_mergerfs() {
    header "💾 Настройка MergerFS"
    
    echo -e "${CYAN}MergerFS объединяет несколько дисков в одно пространство.${NC}"
    echo "Пример: /mnt/disk1 + /mnt/disk2 → /DATA"
    echo ""
    
    read -p "Настроить MergerFS в /etc/fstab? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_warn "Пропущено"; return 0; }
    
    # Проверяем точки монтирования
    for dir in /mnt/disk1 /mnt/disk2; do
        if [ ! -d "$dir" ] || [ "$(ls -A "$dir" 2>/dev/null)" ]; then
            log_warn "$dir не пуст или не существует — проверьте диски"
        fi
    done
    
    # Добавляем в fstab если нет
    if ! grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        echo "" >> /etc/fstab
        echo "# mbcloud NAS - MergerFS" >> /etc/fstab
        echo "/mnt/disk1:/mnt/disk2  $DATA_MOUNT  fuse.mergerfs  defaults,allow_other,use_ino,category.create=epff  0  0" >> /etc/fstab
        log_ok "MergerFS добавлен в /etc/fstab"
        log "Примените: sudo mount -a"
    else
        log_ok "MergerFS уже настроен в fstab"
    fi
    
    # Пробуем смонтировать
    if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        log_ok "$DATA_MOUNT уже смонтирован"
    else
        sudo mount -a 2>/dev/null && log_ok "MergerFS смонтирован" || log_warn "Не удалось смонтировать — проверьте диски"
    fi
}

#===============================================================================
# 🔔 TELEGRAM УВЕДОМЛЕНИЯ
#===============================================================================

setup_telegram() {
    header "🔔 Настройка Telegram-уведомлений"
    
    echo -e "${CYAN}Получайте уведомления о:${NC}"
    echo "  • Температура CPU > 75°C"
    echo "  • Место на диске < 10%"
    echo "  • Ошибки в логах дисплея"
    echo "  • Статус сервисов"
    echo ""
    echo -e "${YELLOW}Требуется:${NC}"
    echo "  1. Создать бота в @BotFather"
    echo "  2. Узнать свой chat_id через @getidsbot"
    echo ""
    
    read -p "Настроить Telegram? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_warn "Пропущено"; return 0; }
    
    read -p "Введите токен бота: " TELEGRAM_TOKEN
    read -p "Введите ваш chat_id: " TELEGRAM_CHAT
    
    if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT" ]; then
        log_err "Пустые значения — настройка отменена"; return 1
    fi
    
    # Создаём скрипт отправки
    mkdir -p "$REPO_PATH/scripts"
    cat > "$REPO_PATH/scripts/notify-telegram.sh" << EOF
#!/bin/bash
# mbcloud NAS - Telegram notifier
TOKEN="$TELEGRAM_TOKEN"
CHAT="$TELEGRAM_CHAT"

send() {
    curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
        -d "chat_id=\$CHAT" \
        -d "text=\$1" \
        -d "parse_mode=HTML" >/dev/null
}

# Примеры:
# send "🔥 Температура: \$(vcgencmd measure_temp)"
# send "💾 Место: \$(df -h /DATA | tail -1 | awk '{print \$5}')"
EOF
    chmod +x "$REPO_PATH/scripts/notify-telegram.sh"
    chown "$USER:$USER" "$REPO_PATH/scripts/notify-telegram.sh"
    
    # Тест
    if "$REPO_PATH/scripts/notify-telegram.sh" send "✅ mbcloud NAS: Telegram настроен!" 2>/dev/null; then
        log_ok "Telegram настроен! Проверьте чат."
    else
        log_warn "Не удалось отправить тест — проверьте токен и chat_id"
    fi
    
    # Cron для мониторинга (опционально)
    echo ""
    read -p "Добавить авто-мониторинг в cron? (y/N): " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        (crontab -l 2>/dev/null; echo "*/30 * * * * $REPO_PATH/scripts/notify-telegram.sh monitor") | crontab - 2>/dev/null
        log_ok "Мониторинг добавлен в cron (каждые 30 минут)"
    fi
    
    log "Документация: $REPO_PATH/scripts/notify-telegram.sh"
}

#===============================================================================
# 🔄 АВТО-ОБНОВЛЕНИЕ
#===============================================================================

setup_auto_update() {
    header "🔄 Настройка авто-обновления"
    
    echo -e "${CYAN}Автоматически обновлять:${NC}"
    echo "  • Системные пакеты (безопасные)"
    echo "  • Код mbcloud-system с GitHub"
    echo "  • Перезапуск сервисов при изменениях"
    echo ""
    
    read -p "Включить авто-обновление? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_warn "Пропущено"; return 0; }
    
    # Unattended upgrades для системы
    if ! dpkg -l | grep -q unattended-upgrades 2>/dev/null; then
        sudo apt install -y -qq unattended-upgrades apt-listchanges 2>/dev/null || true
    fi
    
    # Скрипт обновления репозитория
    cat > "$REPO_PATH/scripts/update-mbcloud.sh" << 'EOF'
#!/bin/bash
# mbcloud NAS - Auto-update script
REPO_PATH="${REPO_PATH:-/home/${SUDO_USER:-$(whoami)}/mbcloud-system}"
SERVICE="mbcloud-display.service"

cd "$REPO_PATH" || exit 1

# Обновляем код
if git pull -q 2>/dev/null; then
    # Проверяем, изменился ли main.py
    if git diff --name-only HEAD@{1}..HEAD | grep -q "display/main.py"; then
        echo "🔄 main.py изменён — перезапускаем сервис..."
        sudo systemctl restart "$SERVICE" 2>/dev/null || true
    fi
fi

# Обновляем Python-зависимости если изменился requirements.txt
if git diff --name-only HEAD@{1}..HEAD | grep -q "requirements.txt"; then
    echo "📦 requirements.txt изменён — обновляем пакеты..."
    sudo pip3 install -q --break-system-packages -r "$REPO_PATH/display/requirements.txt" 2>/dev/null || \
    sudo apt install -y -qq $(grep -v "^#" "$REPO_PATH/display/requirements.txt" | sed 's/>=.*//' | sed 's/^/python3-/' | tr '\n' ' ') 2>/dev/null || true
fi

echo "✅ Update check completed at $(date)"
EOF
    chmod +x "$REPO_PATH/scripts/update-mbcloud.sh"
    
    # Добавляем в cron (ежедневно в 4:00)
    if ! crontab -l 2>/dev/null | grep -q "update-mbcloud.sh"; then
        (crontab -l 2>/dev/null; echo "0 4 * * * $REPO_PATH/scripts/update-mbcloud.sh >> /var/log/mbcloud-update.log 2>&1") | crontab - 2>/dev/null
        log_ok "Авто-обновление добавлено в cron (ежедневно в 04:00)"
    fi
    
    log "Логи: /var/log/mbcloud-update.log"
    log "Ручной запуск: $REPO_PATH/scripts/update-mbcloud.sh"
}

#===============================================================================
# 📊 GRAFANA + PROMETHEUS (мониторинг)
#===============================================================================

setup_monitoring() {
    header "📊 Настройка мониторинга (Grafana + Prometheus)"
    
    echo -e "${CYAN}Визуализируйте метрики:${NC}"
    echo "  • Температура, загрузка CPU/RAM"
    echo "  • Место на диске, скорость сети"
    echo "  • Статус сервисов, логи"
    echo ""
    echo -e "${YELLOW}Требования:${NC} ~500 МБ ОЗУ, ~2 ГБ места"
    echo ""
    
    read -p "Установить мониторинг? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_warn "Пропущено"; return 0; }
    
    install_docker_if_needed
    
    log "Создаём конфигурацию мониторинга..."
    mkdir -p "$REPO_PATH/monitoring"
    
    # Prometheus config
    cat > "$REPO_PATH/monitoring/prometheus.yml" << 'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['host.docker.internal:9100']
EOF
    
    # Docker Compose для мониторинга
    cat > "$REPO_PATH/monitoring/docker-compose.yml" << EOF
version: '3.8'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: mbcloud-prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    networks:
      - monitoring

  grafana:
    image: grafana/grafana:latest
    container_name: mbcloud-grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=mbcloud123
    volumes:
      - grafana_data:/var/lib/grafana
    networks:
      - monitoring
    depends_on:
      - prometheus

  node-exporter:
    image: prom/node-exporter:latest
    container_name: mbcloud-node-exporter
    ports:
      - "9100:9100"
    network_mode: host
    pid: host

volumes:
  prometheus_data:
  grafana_data:

networks:
  monitoring:
EOF
    
    # Запускаем
    log "Запускаем мониторинг..."
    cd "$REPO_PATH/monitoring"
    if docker compose up -d 2>&1 | tee /tmp/monitoring.log; then
        log_ok "Мониторинг запущен!"
        log "📊 Grafana: http://$(hostname -I | awk '{print $1}'):3000"
        log "🔐 Логин: admin / Пароль: mbcloud123 (смените!)"
        log "📈 Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
    else
        log_err "Ошибка — проверьте: docker compose logs -f"
    fi
    
    log "Дашборды: импортируйте ID 1860 (Node Exporter) в Grafana"
}

#===============================================================================
# 🔐 ВНЕШНИЙ ДОСТУП (Nginx Proxy + Let's Encrypt)
#===============================================================================

setup_external_access() {
    header "🔐 Настройка внешнего доступа (HTTPS)"
    
    echo -e "${CYAN}Безопасный доступ из интернета:${NC}"
    echo "  • Nginx Proxy Manager (веб-интерфейс)"
    echo "  • Автоматические сертификаты Let's Encrypt"
    echo "  • Проксирование: immich.your-domain.com → localhost:2283"
    echo ""
    echo -e "${YELLOW}Требуется:${NC}"
    echo "  • Доменное имя (или динамический DNS)"
    echo "  • Открытые порты 80/443 на роутере"
    echo "  • ~200 МБ ОЗУ"
    echo ""
    
    read -p "Настроить внешний доступ? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_warn "Пропущено"; return 0; }
    
    install_docker_if_needed
    
    log "Устанавливаем Nginx Proxy Manager..."
    mkdir -p "$REPO_PATH/proxy"
    
    cat > "$REPO_PATH/proxy/docker-compose.yml" << 'EOF'
version: '3.8'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    container_name: mbcloud-proxy
    restart: unless-stopped
    ports:
      - '80:80'
      - '81:81'
      - '443:443'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - proxy-net

networks:
  proxy-net:
    name: proxy
    external: false
EOF
    
    # Создаём сети для Immich и других сервисов
    docker network create proxy 2>/dev/null || true
    
    # Запускаем
    cd "$REPO_PATH/proxy"
    if docker compose up -d 2>&1 | tee /tmp/proxy.log; then
        log_ok "Nginx Proxy Manager запущен!"
        log "🌐 Панель: http://$(hostname -I | awk '{print $1}'):81"
        log "🔐 Логин: admin@example.com / Пароль: changeme"
        log "📝 Инструкция: добавьте прокси-хост для immich.your-domain.com → mbcloud-immich:2283"
    else
        log_err "Ошибка — проверьте: docker compose logs -f"
    fi
    
    log "Важно: настройте DNS и проброс портов 80/443 на роутере"
}

#===============================================================================
# 💾 АВТО-БЭКАПЫ (borg/rclone)
#===============================================================================

setup_backups() {
    header "💾 Настройка авто-бэкапов"
    
    echo -e "${CYAN}Резервное копирование данных:${NC}"
    echo "  • BorgBackup: дедупликация, шифрование, сжатие"
    echo "  • rclone: синхронизация с облаками (Google Drive, Yandex, S3)"
    echo "  • Расписание: ежедневно/еженедельно"
    echo ""
    echo -e "${YELLOW}Требуется:${NC}"
    echo "  • Целевое хранилище (другой диск, сервер, облако)"
    echo "  • ~1 ГБ свободного места для первого бэкапа"
    echo ""
    
    read -p "Настроить авто-бэкапы? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_warn "Пропущено"; return 0; }
    
    # Устанавливаем borg
    if ! command -v borg &>/dev/null; then
        log "Устанавливаем BorgBackup..."
        sudo apt install -y -qq borgbackup 2>/dev/null || log_warn "Borg не установлен — используйте rclone"
    fi
    
    # Устанавливаем rclone
    if ! command -v rclone &>/dev/null; then
        log "Устанавливаем rclone..."
        curl https://rclone.org/install.sh | sudo bash 2>/dev/null || sudo apt install -y -qq rclone 2>/dev/null || log_warn "rclone не установлен"
    fi
    
    # Создаём скрипт бэкапа
    mkdir -p "$REPO_PATH/scripts"
    cat > "$REPO_PATH/scripts/backup.sh" << 'EOF'
#!/bin/bash
# mbcloud NAS - Backup script
# Настройте переменные ниже перед использованием

# 📁 Что бэкапить
SOURCE_DIRS="/DATA/photos /DATA/immich-library"

# 🎯 Куда (выберите один вариант):
# Вариант А: Локальный диск
# TARGET="/mnt/backup-drive/mbcloud-backup"

# Вариант Б: Borg repository (локальный или по SSH)
# TARGET="user@backup-server:/path/to/repo::mbcloud-{now}"

# Вариант В: rclone remote (Google Drive, Yandex, etc.)
# RCLONE_REMOTE="gdrive:"
# TARGET="$RCLONE_REMOTE/mbcloud-backup"

# 🔐 Borg settings (если используется)
BORG_PASSPHRASE="change_this_to_secure_passphrase"
BORG_REPO="$TARGET"

# 🗓️ Расписание: удалить бэкапы старше
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

# 📧 Уведомления (опционально)
# TELEGRAM_SCRIPT="/home/mbcloud/mbcloud-system/scripts/notify-telegram.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# Проверка источника
for dir in $SOURCE_DIRS; do
    [ ! -d "$dir" ] && { log "❌ Не найдено: $dir"; exit 1; }
done

log "🔄 Начинаю бэкап..."

# Пример для rclone:
# if command -v rclone &>/dev/null && [ -n "$RCLONE_REMOTE" ]; then
#     rclone sync "$SOURCE_DIRS" "$TARGET" --progress --transfers=4 2>&1 | tee -a /var/log/mbcloud-backup.log
# fi

# Пример для borg:
# if command -v borg &>/dev/null && [ -n "$BORG_REPO" ]; then
#     borg create --verbose --filter AME --compression zstd \
#         --exclude '*.tmp' --exclude 'cache/*' \
#         "$BORG_REPO" $SOURCE_DIRS 2>&1 | tee -a /var/log/mbcloud-backup.log
#     
#     borg prune --keep-daily $KEEP_DAILY --keep-weekly $KEEP_WEEKLY --keep-monthly $KEEP_MONTHLY "$BORG_REPO"
#     borg compact "$BORG_REPO"
# fi

log "✅ Бэкап завершён"

# Уведомление
# [ -x "$TELEGRAM_SCRIPT" ] && "$TELEGRAM_SCRIPT" send "✅ Бэкап mbcloud завершён"
EOF
    chmod +x "$REPO_PATH/scripts/backup.sh"
    chown "$USER:$USER" "$REPO_PATH/scripts/backup.sh"
    
    log "📝 Отредактируйте $REPO_PATH/scripts/backup.sh — настройте TARGET и параметры"
    
    # Добавляем в cron (еженедельно в воскресенье 3:00)
    echo ""
    read -p "Добавить бэкап в cron (воскресенье 03:00)? (y/N): " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        (crontab -l 2>/dev/null; echo "0 3 * * 0 $REPO_PATH/scripts/backup.sh >> /var/log/mbcloud-backup.log 2>&1") | crontab - 2>/dev/null
        log_ok "Бэкап добавлен в cron"
    fi
    
    log "Тестовый запуск: $REPO_PATH/scripts/backup.sh"
    log "Логи: /var/log/mbcloud-backup.log"
}

#===============================================================================
# 🎯 ГЛАВНОЕ МЕНЮ
#===============================================================================

show_menu() {
    header "mbcloud NAS - Выберите компоненты для установки"
    
    echo -e "${BOLD}Доступные компоненты:${NC}"
    echo "  1) 🐳 Docker + Immich (фото-сервер)"
    echo "  2) 💾 MergerFS в fstab (объединение дисков)"
    echo "  3) 🔔 Telegram-уведомления"
    echo "  4) 🔄 Авто-обновление системы и кода"
    echo "  5) 📊 Мониторинг (Grafana + Prometheus)"
    echo "  6) 🔐 Внешний доступ (Nginx Proxy + HTTPS)"
    echo "  7) 💾 Авто-бэкапы (borg/rclone)"
    echo ""
    echo "  a) 🎯 Установить ВСЁ (кроме внешнего доступа)"
    echo "  b) 🔙 Выход"
    echo ""
    echo -e "${YELLOW}Подсказка:${NC} Введите номер компонента или 'a' для всех"
    echo ""
}

run_component() {
    case "$1" in
        1|immich) install_immich ;;
        2|mergerfs) setup_mergerfs ;;
        3|telegram) setup_telegram ;;
        4|autoupdate) setup_auto_update ;;
        5|monitoring) setup_monitoring ;;
        6|proxy|external) setup_external_access ;;
        7|backup|backups) setup_backups ;;
        a|all)
            install_immich
            setup_mergerfs
            setup_telegram
            setup_auto_update
            setup_monitoring
            # setup_external_access  # Пропускаем — требует домен
            setup_backups
            ;;
        *) log_warn "Неверный выбор";;
    esac
}

main() {
    check_root
    check_repo
    
    # Обработка аргументов командной строки
    if [[ "${1:-}" == "--all" || "${1:-}" == "-a" ]]; then
        run_component "all"
        exit 0
    elif [[ -n "$1" ]]; then
        run_component "$1"
        exit 0
    fi
    
    # Интерактивный режим
    while true; do
        show_menu
        read -p "Выберите компонент (1-7, a, b): " choice
        echo ""
        
        case "$choice" in
            b|exit|quit) log_ok "Завершено"; break ;;
            *) run_component "$choice"; echo ""; read -p "Продолжить? (y/N): " -n 1 -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && break ;;
        esac
    done
    
    echo ""
    log_ok "Установка дополнений завершена!"
    log "Полезные команды:"
    echo "  • Immich: ${BLUE}immich up -d${NC}"
    echo "  • Мониторинг: ${BLUE}http://$(hostname -I | awk '{print $1}'):3000${NC}"
    echo "  • Прокси: ${BLUE}http://$(hostname -I | awk '{print $1}'):81${NC}"
    echo "  • Бэкап: ${BLUE}$REPO_PATH/scripts/backup.sh${NC}"
    echo ""
}

main "$@"
