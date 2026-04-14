#!/bin/bash
#===============================================================================
# mbcloud NAS - Установка дополнительных компонентов (v1.1)
# Использование:
#   • Интерактивно:  curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/install-addons.sh | sudo bash
#   • Рекомендуемо:  ... | sudo bash -s -- --recommended
#   • Только Immich: ... | sudo bash -s -- --immich
#   • Без Telegram:  ... | sudo bash -s -- --full --no-telegram
#===============================================================================

# 🎨 Цвета (ПРАВИЛЬНОЕ экранирование!)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ⚙️ Конфигурация
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_PATH="${REPO_PATH:-/home/${SUDO_USER:-$(whoami)}/mbcloud-system}"
DATA_MOUNT="/DATA"
USER="${SUDO_USER:-$(whoami)}"
DOCKER_DIR="$REPO_PATH/docker"

# 🎛️ Флаги (устанавливаются из аргументов)
MODE="interactive"
SKIP_TELEGRAM=false
SKIP_MONITORING=false
SKIP_PROXY=false
SKIP_BACKUP=false
INSTALL_IMMICH=false
INSTALL_MERGERFS=false
INSTALL_AUTOUPDATE=false

# 📢 Функции вывода
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_err() { echo -e "${RED}[✗]${NC} $1"; }

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║  mbcloud NAS - Addons Installer v1.1 ║${NC}"
    echo -e "${CYAN}${BOLD}╚════════════════════════════════════╝${NC}"
    echo "  $(date '+%Y-%m-%d %H:%M:%S') | Mode: $MODE | User: $USER"
    echo ""
}

#===============================================================================
# 🔧 ОБЩИЕ ФУНКЦИИ
#===============================================================================

check_root() {
    [[ $EUID -ne 0 ]] && { log_err "Запустите с: curl ... | sudo bash"; exit 1; }
}

check_repo() {
    # Если репозиторий уже есть — не клонируем заново
    if [ -d "$REPO_PATH/.git" ]; then
        log_ok "Репозиторий уже существует: $REPO_PATH"
        return 0
    fi
    log "Клонируем репозиторий..."
    git clone -b "$REPO_BRANCH" "https://github.com/mibitok/mbcloud-system.git" "$REPO_PATH" 2>/dev/null || {
        log_warn "Не удалось клонировать — используем базовые настройки"
        REPO_PATH="/home/$USER/mbcloud-system"
    }
}

install_docker_if_needed() {
    if ! command -v docker &>/dev/null; then
        log "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null && sudo sh /tmp/get-docker.sh 2>/dev/null && {
            sudo usermod -aG docker "$USER" 2>/dev/null
            log_ok "Docker установлен"
        } || {
            sudo apt install -y -qq docker.io docker-compose-plugin 2>/dev/null && log_ok "Docker установлен через apt"
        }
        rm -f /tmp/get-docker.sh
    else
        log_ok "Docker уже установлен"
    fi
    newgrp docker 2>/dev/null || true
}

ask_confirm() {
    # Если режим не интерактивный — возвращаем значение по умолчанию ($1)
    if [[ "$MODE" != "interactive" ]]; then
        [[ "$1" == "true" ]] && return 0 || return 1
    fi
    # Интерактивный режим — спрашиваем пользователя
    read -p "$2 (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

#===============================================================================
# 🐳 DOCKER + IMMICH
#===============================================================================

install_immich() {
    # Пропускаем если не запрошено и не полный режим
    [[ "$INSTALL_IMMICH" == "false" && "$MODE" != "full" ]] && return 0
    # Спрашиваем в интерактивном режиме
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "🐳 Установить Immich?" || return 0
    
    header "🐳 Установка Immich"
    log "Immich — само-хостимый сервис для синхронизации фото."
    
    install_docker_if_needed
    
    # Проверяем место на диске
    local free=$(df -BG "$DATA_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ -n "$free" && "$free" -lt 10 ]]; then
        log_warn "Мало места на $DATA_MOUNT: ${free}GB (нужно минимум 10 ГБ)"
        [[ "$MODE" == "interactive" ]] && { read -p "Продолжить? (y/N): " -n 1 -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
    fi
    
    log "Настраиваем Immich..."
    mkdir -p "$DOCKER_DIR"
    
    if [[ ! -f "$DOCKER_DIR/.env" && -f "$DOCKER_DIR/.env.example" ]]; then
        cp "$DOCKER_DIR/.env.example" "$DOCKER_DIR/.env"
        local pass=$(openssl rand -hex 16 2>/dev/null || echo "mbcloud_$(date +%s)")
        sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$pass/" "$DOCKER_DIR/.env"
        chown "$USER:$USER" "$DOCKER_DIR/.env"
        log_ok "Файл .env создан с надёжным паролем"
    fi
    
    # Создаём папки для Immich
    for dir in upload library postgres redis; do
        mkdir -p "$DATA_MOUNT/immich-$dir"
    done
    chown -R 999:999 "$DATA_MOUNT/immich-postgres" "$DATA_MOUNT/immich-redis" 2>/dev/null || true
    
    # Запускаем
    log "Запускаем Immich (может занять 2-5 минут)..."
    cd "$DOCKER_DIR"
    if docker compose up -d 2>&1 | tee /tmp/immich.log; then
        log_ok "Immich запущен! 🌐 http://$(hostname -I | awk '{print $1}'):2283"
        log "📱 Приложение: укажите тот же адрес, первый пользователь = админ"
    else
        log_err "Ошибка запуска — проверьте: docker compose logs -f"
    fi
    
    # Алиас для удобства
    grep -q "alias immich=" ~/.bashrc 2>/dev/null || echo "alias immich='cd $DOCKER_DIR && docker compose'" >> ~/.bashrc
    log "Добавлен алиас: ${BLUE}immich${NC}"
}

#===============================================================================
# 💾 MERGERFS В FSTAB
#===============================================================================

setup_mergerfs() {
    [[ "$INSTALL_MERGERFS" == "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "💾 Настроить MergerFS в fstab?" || return 0
    
    header "💾 Настройка MergerFS"
    
    if ! grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        echo "" >> /etc/fstab
        echo "# mbcloud NAS - MergerFS" >> /etc/fstab
        echo "/mnt/disk1:/mnt/disk2  $DATA_MOUNT  fuse.mergerfs  defaults,allow_other,use_ino,category.create=epff  0  0" >> /etc/fstab
        log_ok "MergerFS добавлен в /etc/fstab"
        sudo mount -a 2>/dev/null && log_ok "MergerFS смонтирован" || log_warn "Не удалось смонтировать — проверьте диски"
    else
        log_ok "MergerFS уже настроен в fstab"
    fi
}

#===============================================================================
# 🔔 TELEGRAM (опционально, по умолчанию пропускать)
#===============================================================================

setup_telegram() {
    [[ "$SKIP_TELEGRAM" == "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "🔔 Настроить Telegram-уведомления?" || return 0
    
    header "🔔 Настройка Telegram"
    log "Требуется: создать бота в @BotFather, узнать chat_id через @getidsbot"
    
    read -p "Токен бота: " TELEGRAM_TOKEN
    read -p "Ваш chat_id: " TELEGRAM_CHAT
    
    if [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT" ]]; then
        log_err "Пустые значения — настройка отменена"
        return 1
    fi
    
    mkdir -p "$REPO_PATH/scripts"
    cat > "$REPO_PATH/scripts/notify-telegram.sh" << EOF
#!/bin/bash
# mbcloud NAS - Telegram notifier
TOKEN="$TELEGRAM_TOKEN"
CHAT="$TELEGRAM_CHAT"
send() {
    curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \\
        -d "chat_id=\$CHAT" \\
        -d "text=\$1" \\
        -d "parse_mode=HTML" >/dev/null
}
# Пример: send "🔥 Температура: \$(vcgencmd measure_temp)"
EOF
    chmod +x "$REPO_PATH/scripts/notify-telegram.sh"
    chown "$USER:$USER" "$REPO_PATH/scripts/notify-telegram.sh"
    
    if "$REPO_PATH/scripts/notify-telegram.sh" send "✅ mbcloud NAS: Telegram настроен!" 2>/dev/null; then
        log_ok "Telegram настроен! Проверьте чат."
    else
        log_warn "Не удалось отправить тест — проверьте токен и chat_id"
    fi
}

#===============================================================================
# 🔄 АВТО-ОБНОВЛЕНИЕ
#===============================================================================

setup_auto_update() {
    [[ "$INSTALL_AUTOUPDATE" == "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "🔄 Включить авто-обновление?" || return 0
    
    header "🔄 Настройка авто-обновления"
    
    # Unattended upgrades для системы
    dpkg -l | grep -q unattended-upgrades 2>/dev/null || sudo apt install -y -qq unattended-upgrades apt-listchanges 2>/dev/null || true
    
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
    if git diff --name-only HEAD@{1}..HEAD 2>/dev/null | grep -q "display/main.py"; then
        echo "🔄 main.py изменён — перезапускаем сервис..."
        sudo systemctl restart "$SERVICE" 2>/dev/null || true
    fi
fi

# Обновляем Python-зависимости если изменился requirements.txt
if git diff --name-only HEAD@{1}..HEAD 2>/dev/null | grep -q "requirements.txt"; then
    echo "📦 requirements.txt изменён — обновляем пакеты..."
    sudo pip3 install -q --break-system-packages -r "$REPO_PATH/display/requirements.txt" 2>/dev/null || true
fi

echo "✅ Update check completed at $(date)"
EOF
    chmod +x "$REPO_PATH/scripts/update-mbcloud.sh"
    chown "$USER:$USER" "$REPO_PATH/scripts/update-mbcloud.sh"
    
    # Добавляем в cron (ежедневно в 4:00)
    if ! crontab -l 2>/dev/null | grep -q "update-mbcloud.sh"; then
        (crontab -l 2>/dev/null; echo "0 4 * * * $REPO_PATH/scripts/update-mbcloud.sh >> /var/log/mbcloud-update.log 2>&1") | crontab - 2>/dev/null
        log_ok "Авто-обновление добавлено в cron (ежедневно в 04:00)"
    fi
    
    log "Логи: /var/log/mbcloud-update.log"
    log "Ручной запуск: $REPO_PATH/scripts/update-mbcloud.sh"
}

#===============================================================================
# 📊 МОНИТОРИНГ (опционально)
#===============================================================================

setup_monitoring() {
    [[ "$SKIP_MONITORING" == "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "📊 Установить мониторинг (Grafana+Prometheus)?" || return 0
    
    header "📊 Настройка мониторинга"
    install_docker_if_needed
    
    mkdir -p "$REPO_PATH/monitoring"
    
    cat > "$REPO_PATH/monitoring/docker-compose.yml" << 'EOF'
version: '3.8'
services:
  grafana:
    image: grafana/grafana:latest
    container_name: mbcloud-grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=mbcloud123
    volumes:
      - grafana_/var/lib/grafana
    restart: unless-stopped
volumes:
  grafana_:
EOF
    
    cd "$REPO_PATH/monitoring"
    if docker compose up -d 2>&1 | tee /tmp/monitoring.log; then
        log_ok "Grafana запущен! 📊 http://$(hostname -I | awk '{print $1}'):3000"
        log "🔐 Логин: admin / Пароль: mbcloud123 (смените!)"
    else
        log_err "Ошибка — проверьте: docker compose logs -f"
    fi
}

#===============================================================================
# 🔐 ВНЕШНИЙ ДОСТУП (опционально)
#===============================================================================

setup_external_access() {
    [[ "$SKIP_PROXY" == "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "🔐 Настроить внешний доступ (Nginx Proxy + HTTPS)?" || return 0
    
    header "🔐 Настройка внешнего доступа"
    install_docker_if_needed
    
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
EOF
    
    docker network create proxy 2>/dev/null || true
    cd "$REPO_PATH/proxy"
    if docker compose up -d 2>&1 | tee /tmp/proxy.log; then
        log_ok "Nginx Proxy Manager запущен! 🔐 http://$(hostname -I | awk '{print $1}'):81"
        log "🔐 Логин: admin@example.com / Пароль: changeme"
    else
        log_err "Ошибка — проверьте: docker compose logs -f"
    fi
}

#===============================================================================
# 💾 БЭКАПЫ (опционально)
#===============================================================================

setup_backups() {
    [[ "$SKIP_BACKUP" == "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "💾 Настроить авто-бэкапы?" || return 0
    
    header "💾 Настройка авто-бэкапов"
    
    # Устанавливаем borg если нет
    command -v borg &>/dev/null || sudo apt install -y -qq borgbackup 2>/dev/null || true
    
    # Устанавливаем rclone если нет
    if ! command -v rclone &>/dev/null; then
        log "Устанавливаем rclone..."
        curl -s https://rclone.org/install.sh | sudo bash 2>/dev/null || sudo apt install -y -qq rclone 2>/dev/null || true
    fi
    
    mkdir -p "$REPO_PATH/scripts"
    cat > "$REPO_PATH/scripts/backup.sh" << 'EOF'
#!/bin/bash
# mbcloud NAS - Backup script
# Настройте TARGET перед использованием!

# 📁 Что бэкапить
SOURCE_DIRS="/DATA/photos /DATA/immich-library"

# 🎯 Куда (раскомментируйте и настройте один вариант):
# Вариант А: Локальный диск
# TARGET="/mnt/backup-drive/mbcloud-backup"

# Вариант Б: Borg repository (локальный или по SSH)
# TARGET="user@backup-server:/path/to/repo::mbcloud-{now}"
# BORG_PASSPHRASE="change_this_to_secure_passphrase"

# Вариант В: rclone remote (Google Drive, Yandex, etc.)
# RCLONE_REMOTE="gdrive:"
# TARGET="$RCLONE_REMOTE/mbcloud-backup"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# Проверка источника
for dir in $SOURCE_DIRS; do
    [ ! -d "$dir" ] && { log "❌ Не найдено: $dir"; exit 1; }
done

log "🔄 Начинаю бэкап..."

# Пример для rclone:
# if command -v rclone &>/dev/null && [ -n "${RCLONE_REMOTE:-}" ]; then
#     rclone sync "$SOURCE_DIRS" "$TARGET" --progress --transfers=4 2>&1 | tee -a /var/log/mbcloud-backup.log
# fi

# Пример для borg:
# if command -v borg &>/dev/null && [ -n "${BORG_PASSPHRASE:-}" ]; then
#     export BORG_PASSPHRASE
#     borg create --verbose --filter AME --compression zstd \
#         --exclude '*.tmp' --exclude 'cache/*' \
#         "$TARGET" $SOURCE_DIRS 2>&1 | tee -a /var/log/mbcloud-backup.log
#     borg prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6 "$TARGET"
#     borg compact "$TARGET"
# fi

log "✅ Бэкап завершён"
EOF
    chmod +x "$REPO_PATH/scripts/backup.sh"
    chown "$USER:$USER" "$REPO_PATH/scripts/backup.sh"
    
    log "📝 Отредактируйте $REPO_PATH/scripts/backup.sh — настройте TARGET и метод"
    
    # Добавляем в cron (еженедельно в воскресенье 3:00)
    echo ""
    if [[ "$MODE" == "interactive" ]]; then
        read -p "Добавить бэкап в cron (воскресенье 03:00)? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            (crontab -l 2>/dev/null; echo "0 3 * * 0 $REPO_PATH/scripts/backup.sh >> /var/log/mbcloud-backup.log 2>&1") | crontab - 2>/dev/null
            log_ok "Бэкап добавлен в cron"
        fi
    fi
    
    log "Тестовый запуск: $REPO_PATH/scripts/backup.sh"
    log "Логи: /var/log/mbcloud-backup.log"
}

#===============================================================================
# 🎛️ ПАРСИНГ АРГУМЕНТОВ
#===============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --minimal)
                MODE="minimal"
                INSTALL_IMMICH=false; INSTALL_MERGERFS=false; INSTALL_AUTOUPDATE=false
                SKIP_TELEGRAM=true; SKIP_MONITORING=true; SKIP_PROXY=true; SKIP_BACKUP=true
                shift ;;
            --recommended)
                MODE="recommended"
                INSTALL_IMMICH=true; INSTALL_MERGERFS=true; INSTALL_AUTOUPDATE=true
                SKIP_TELEGRAM=true; SKIP_MONITORING=true; SKIP_PROXY=true; SKIP_BACKUP=true
                shift ;;
            --full)
                MODE="full"
                INSTALL_IMMICH=true; INSTALL_MERGERFS=true; INSTALL_AUTOUPDATE=true
                SKIP_TELEGRAM=false; SKIP_MONITORING=false; SKIP_PROXY=false; SKIP_BACKUP=false
                shift ;;
            --all)
                # --all = recommended (без Telegram/proxy по умолчанию)
                MODE="recommended"
                INSTALL_IMMICH=true; INSTALL_MERGERFS=true; INSTALL_AUTOUPDATE=true
                SKIP_TELEGRAM=true; SKIP_MONITORING=true; SKIP_PROXY=true; SKIP_BACKUP=true
                shift ;;
            --immich) INSTALL_IMMICH=true; MODE="custom"; shift ;;
            --mergerfs) INSTALL_MERGERFS=true; MODE="custom"; shift ;;
            --autoupdate) INSTALL_AUTOUPDATE=true; MODE="custom"; shift ;;
            --telegram) SKIP_TELEGRAM=false; MODE="custom"; shift ;;
            --monitoring) SKIP_MONITORING=false; MODE="custom"; shift ;;
            --proxy|--external) SKIP_PROXY=false; MODE="custom"; shift ;;
            --backup) SKIP_BACKUP=false; MODE="custom"; shift ;;
            --no-telegram) SKIP_TELEGRAM=true; shift ;;
            --no-monitoring) SKIP_MONITORING=true; shift ;;
            --no-proxy) SKIP_PROXY=true; shift ;;
            --no-backup) SKIP_BACKUP=true; shift ;;
            -h|--help)
                echo "mbcloud NAS - Addons Installer v1.1"
                echo ""
                echo "Режимы:"
                echo "  --recommended  Immich + MergerFS + авто-обновление ⭐ РЕКОМЕНДУЕТСЯ"
                echo "  --full         Все компоненты (включая Telegram, мониторинг, proxy, бэкапы)"
                echo ""
                echo "Отдельные компоненты:"
                echo "  --immich --mergerfs --autoupdate --telegram --monitoring --proxy --backup"
                echo ""
                echo "Исключения (для --full):"
                echo "  --no-telegram --no-monitoring --no-proxy --no-backup"
                echo ""
                echo "Примеры:"
                echo "  ... | sudo bash -s -- --recommended"
                echo "  ... | sudo bash -s -- --immich --mergerfs"
                echo "  ... | sudo bash -s -- --full --no-telegram"
                exit 0 ;;
            *) log_warn "Неизвестный аргумент: $1"; shift ;;
        esac
    done
}

#===============================================================================
# 🎯 ГЛАВНАЯ ФУНКЦИЯ
#===============================================================================

main() {
    check_root
    parse_args "$@"
    check_repo
    
    header "mbcloud NAS - Установка компонентов"
    
    case "$MODE" in
        interactive)
            echo -e "${BOLD}Доступные компоненты:${NC}"
            echo "  1) 🐳 Immich (фото-сервер)"
            echo "  2) 💾 MergerFS в fstab"
            echo "  3) 🔔 Telegram-уведомления"
            echo "  4) 🔄 Авто-обновление"
            echo "  5) 📊 Мониторинг (Grafana)"
            echo "  6) 🔐 Внешний доступ (Proxy)"
            echo "  7) 💾 Авто-бэкапы"
            echo "  8) ✅ Рекомендуемый набор (1+2+4)"
            echo "  0) 🔙 Выход"
            echo ""
            read -p "Выберите компонент (1-8, 0): " choice
            echo ""
            case "$choice" in
                1) install_immich ;;
                2) setup_mergerfs ;;
                3) setup_telegram ;;
                4) setup_auto_update ;;
                5) setup_monitoring ;;
                6) setup_external_access ;;
                7) setup_backups ;;
                8) MODE="recommended"; install_immich; setup_mergerfs; setup_auto_update ;;
                *) log_ok "Завершено" ;;
            esac
            ;;
        minimal)
            log "Минимальный режим — ничего не устанавливаем"
            ;;
        recommended|full)
            install_immich
            setup_mergerfs
            setup_auto_update
            if [[ "$MODE" == "full" ]]; then
                setup_telegram
                setup_monitoring
                setup_external_access
                setup_backups
            fi
            ;;
        custom)
            [[ "$INSTALL_IMMICH" == "true" ]] && install_immich
            [[ "$INSTALL_MERGERFS" == "true" ]] && setup_mergerfs
            [[ "$INSTALL_AUTOUPDATE" == "true" ]] && setup_auto_update
            [[ "$SKIP_TELEGRAM" == "false" ]] && setup_telegram
            [[ "$SKIP_MONITORING" == "false" ]] && setup_monitoring
            [[ "$SKIP_PROXY" == "false" ]] && setup_external_access
            [[ "$SKIP_BACKUP" == "false" ]] && setup_backups
            ;;
    esac
    
    echo ""
    log_ok "Установка дополнений завершена!"
    log "Полезные команды:"
    echo -e "  • Immich: ${BLUE}immich up -d${NC}"
    echo -e "  • Grafana: ${BLUE}http://$(hostname -I | awk '{print $1}'):3000${NC}"
    echo -e "  • Proxy: ${BLUE}http://$(hostname -I | awk '{print $1}'):81${NC}"
    echo -e "  • Бэкап: ${BLUE}$REPO_PATH/scripts/backup.sh${NC}"
    echo ""
}

main "$@"
