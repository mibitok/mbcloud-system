cd ~/Projects/mbcloud-system

# 1. Создайте скрипт с правильными цветами
cat > scripts/install-addons.sh << 'SCRIPT_EOF'
#!/bin/bash
#===============================================================================
# mbcloud NAS - Установка дополнительных компонентов (v1.1 - non-interactive flags)
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

# 🎛️ Флаги
MODE="interactive"
SKIP_TELEGRAM=false
SKIP_MONITORING=false
SKIP_PROXY=false
SKIP_BACKUP=false
INSTALL_IMMICH=false
INSTALL_MERGERFS=false
INSTALL_AUTOUPDATE=false

# 📢 Вывод
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

check_root() { [[ $EUID -ne 0 ]] && { log_err "Запустите с: curl ... | sudo bash"; exit 1; }; }

check_repo() {
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
    [[ "$MODE" != "interactive" ]] && return $([ "$1" = "true" ] && echo 0 || echo 1)
    read -p "$2 (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

install_immich() {
    [[ "$INSTALL_IMMICH" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "🐳 Установить Immich?" || return 0
    
    header "🐳 Установка Immich"
    log "Immich — само-хостимый сервис для синхронизации фото."
    install_docker_if_needed
    
    local free=$(df -BG "$DATA_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
    if [ -n "$free" ] && [ "$free" -lt 10 ]; then
        log_warn "Мало места на $DATA_MOUNT: ${free}GB"
        [[ "$MODE" = "interactive" ]] && { read -p "Продолжить? (y/N): " -n 1 -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
    fi
    
    log "Настраиваем Immich..."
    mkdir -p "$DOCKER_DIR"
    if [ ! -f "$DOCKER_DIR/.env" ] && [ -f "$DOCKER_DIR/.env.example" ]; then
        cp "$DOCKER_DIR/.env.example" "$DOCKER_DIR/.env"
        local pass=$(openssl rand -hex 16 2>/dev/null || echo "mbcloud_$(date +%s)")
        sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$pass/" "$DOCKER_DIR/.env"
        chown "$USER:$USER" "$DOCKER_DIR/.env"
        log_ok "Файл .env создан"
    fi
    for dir in upload library postgres redis; do mkdir -p "$DATA_MOUNT/immich-$dir"; done
    chown -R 999:999 "$DATA_MOUNT/immich-postgres" "$DATA_MOUNT/immich-redis" 2>/dev/null || true
    
    log "Запускаем Immich (2-5 минут)..."
    cd "$DOCKER_DIR"
    if docker compose up -d 2>&1 | tee /tmp/immich.log; then
        log_ok "Immich запущен! 🌐 http://$(hostname -I | awk '{print $1}'):2283"
    else
        log_err "Ошибка — проверьте: docker compose logs -f"
    fi
    grep -q "alias immich=" ~/.bashrc 2>/dev/null || echo "alias immich='cd $DOCKER_DIR && docker compose'" >> ~/.bashrc
}

setup_mergerfs() {
    [[ "$INSTALL_MERGERFS" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "💾 Настроить MergerFS в fstab?" || return 0
    header "💾 Настройка MergerFS"
    if ! grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        echo "" >> /etc/fstab
        echo "# mbcloud NAS - MergerFS" >> /etc/fstab
        echo "/mnt/disk1:/mnt/disk2  $DATA_MOUNT  fuse.mergerfs  defaults,allow_other,use_ino,category.create=epff  0  0" >> /etc/fstab
        log_ok "MergerFS добавлен в /etc/fstab"
        sudo mount -a 2>/dev/null && log_ok "MergerFS смонтирован" || log_warn "Не удалось смонтировать"
    else
        log_ok "MergerFS уже настроен"
    fi
}

setup_telegram() {
    [[ "$SKIP_TELEGRAM" = "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "🔔 Настроить Telegram?" || return 0
    header "🔔 Telegram"
    read -p "Токен: " TELEGRAM_TOKEN
    read -p "Chat ID: " TELEGRAM_CHAT
    [[ -z "$TELEGRAM_TOKEN" || -z "$TELEGRAM_CHAT" ]] && { log_err "Пустые значения"; return 1; }
    mkdir -p "$REPO_PATH/scripts"
    cat > "$REPO_PATH/scripts/notify-telegram.sh" << EOF
#!/bin/bash
TOKEN="$TELEGRAM_TOKEN"; CHAT="$TELEGRAM_CHAT"
send() { curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" -d "chat_id=\$CHAT" -d "text=\$1" >/dev/null; }
EOF
    chmod +x "$REPO_PATH/scripts/notify-telegram.sh"
    "$REPO_PATH/scripts/notify-telegram.sh" send "✅ mbcloud: Telegram настроен" 2>/dev/null && log_ok "Telegram настроен!" || log_warn "Проверьте токен"
}

setup_auto_update() {
    [[ "$INSTALL_AUTOUPDATE" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "🔄 Авто-обновление?" || return 0
    header "🔄 Авто-обновление"
    dpkg -l | grep -q unattended-upgrades 2>/dev/null || sudo apt install -y -qq unattended-upgrades 2>/dev/null || true
    cat > "$REPO_PATH/scripts/update-mbcloud.sh" << 'EOF'
#!/bin/bash
REPO_PATH="${REPO_PATH:-/home/${SUDO_USER:-$(whoami)}/mbcloud-system}"
cd "$REPO_PATH" || exit 1
git pull -q 2>/dev/null && git diff --name-only HEAD@{1}..HEAD | grep -q "display/main.py" && sudo systemctl restart mbcloud-display.service 2>/dev/null || true
EOF
    chmod +x "$REPO_PATH/scripts/update-mbcloud.sh"
    crontab -l 2>/dev/null | grep -q "update-mbcloud.sh" || (crontab -l 2>/dev/null; echo "0 4 * * * $REPO_PATH/scripts/update-mbcloud.sh") | crontab - 2>/dev/null
    log_ok "Авто-обновление настроено"
}

setup_monitoring() {
    [[ "$SKIP_MONITORING" = "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "📊 Мониторинг?" || return 0
    header "📊 Мониторинг"
    install_docker_if_needed
    mkdir -p "$REPO_PATH/monitoring"
    cat > "$REPO_PATH/monitoring/docker-compose.yml" << 'EOF'
version: '3.8'
services:
  grafana:
    image: grafana/grafana:latest
    ports: ["3000:3000"]
    environment: [GF_SECURITY_ADMIN_PASSWORD=mbcloud123]
    volumes: [grafana_/var/lib/grafana]
volumes: {grafana_:}
EOF
    cd "$REPO_PATH/monitoring" && docker compose up -d 2>&1 | tee /tmp/monitoring.log && log_ok "Grafana: http://$(hostname -I | awk '{print $1}'):3000" || log_err "Ошибка"
}

setup_external_access() {
    [[ "$SKIP_PROXY" = "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "🔐 Proxy?" || return 0
    header "🔐 Nginx Proxy"
    install_docker_if_needed
    mkdir -p "$REPO_PATH/proxy"
    cat > "$REPO_PATH/proxy/docker-compose.yml" << 'EOF'
version: '3.8'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    ports: ['80:80','81:81','443:443']
    volumes: ['.//data','./letsencrypt:/etc/letsencrypt']
EOF
    docker network create proxy 2>/dev/null || true
    cd "$REPO_PATH/proxy" && docker compose up -d 2>&1 | tee /tmp/proxy.log && log_ok "Proxy: http://$(hostname -I | awk '{print $1}'):81" || log_err "Ошибка"
}

setup_backups() {
    [[ "$SKIP_BACKUP" = "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "💾 Бэкапы?" || return 0
    header "💾 Бэкапы"
    command -v borg &>/dev/null || sudo apt install -y -qq borgbackup 2>/dev/null || true
    command -v rclone &>/dev/null || curl -s https://rclone.org/install.sh | sudo bash 2>/dev/null || true
    mkdir -p "$REPO_PATH/scripts"
    cat > "$REPO_PATH/scripts/backup.sh" << 'EOF'
#!/bin/bash
SOURCE_DIRS="/DATA/photos /DATA/immich-library"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
for dir in $SOURCE_DIRS; do [ ! -d "$dir" ] && { log "❌ Не найдено: $dir"; exit 1; }; done
log "🔄 Бэкап..."
# rclone sync "$SOURCE_DIRS" "$TARGET" --progress
log "✅ Завершён"
EOF
    chmod +x "$REPO_PATH/scripts/backup.sh"
    log "📝 Настройте $REPO_PATH/scripts/backup.sh"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --minimal) MODE="minimal"; INSTALL_IMMICH=false; INSTALL_MERGERFS=false; INSTALL_AUTOUPDATE=false; SKIP_TELEGRAM=true; SKIP_MONITORING=true; SKIP_PROXY=true; SKIP_BACKUP=true; shift ;;
            --recommended) MODE="recommended"; INSTALL_IMMICH=true; INSTALL_MERGERFS=true; INSTALL_AUTOUPDATE=true; SKIP_TELEGRAM=true; SKIP_MONITORING=true; SKIP_PROXY=true; SKIP_BACKUP=true; shift ;;
            --full) MODE="full"; INSTALL_IMMICH=true; INSTALL_MERGERFS=true; INSTALL_AUTOUPDATE=true; SKIP_TELEGRAM=false; SKIP_MONITORING=false; SKIP_PROXY=false; SKIP_BACKUP=false; shift ;;
            --all) MODE="recommended"; shift ;;
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
            -h|--help) echo "Используйте: --recommended, --immich, --no-telegram и т.д."; exit 0 ;;
            *) log_warn "Неизвестный аргумент: $1"; shift ;;
        esac
    done
}

main() {
    check_root
    parse_args "$@"
    check_repo
    header "mbcloud NAS - Установка компонентов"
    
    case "$MODE" in
        interactive)
            echo "1) Immich  2) MergerFS  3) Telegram  4) Auto-update  5) Monitoring  6) Proxy  7) Backups  8) Recommended  0) Exit"
            read -p "Выбор: " c
            case "$c" in
                1) install_immich;; 2) setup_mergerfs;; 3) setup_telegram;; 4) setup_auto_update;;
                5) setup_monitoring;; 6) setup_external_access;; 7) setup_backups;;
                8) MODE="recommended"; install_immich; setup_mergerfs; setup_auto_update;;
                *) log_ok "Завершено";;
            esac;;
        minimal) log "Минимальный режим";;
        recommended|full)
            install_immich; setup_mergerfs; setup_auto_update
            [[ "$MODE" = "full" ]] && { setup_telegram; setup_monitoring; setup_external_access; setup_backups; };;
        custom)
            $INSTALL_IMMICH && install_immich; $INSTALL_MERGERFS && setup_mergerfs; $INSTALL_AUTOUPDATE && setup_auto_update
            [[ "$SKIP_TELEGRAM" = "false" ]] && setup_telegram; [[ "$SKIP_MONITORING" = "false" ]] && setup_monitoring
            [[ "$SKIP_PROXY" = "false" ]] && setup_external_access; [[ "$SKIP_BACKUP" = "false" ]] && setup_backups;;
    esac
    echo ""; log_ok "Готово!"; log "Команды: immich up -d | Grafana: http://$(hostname -I | awk '{print $1}'):3000"
}

main "$@"
SCRIPT_EOF

# 2. Сделайте исполняемым
chmod +x scripts/install-addons.sh

# 3. Проверьте локально (не через curl!)
./scripts/install-addons.sh --help

# 4. Отправьте на GitHub
git add scripts/install-addons.sh
git commit -m "Fix v1.1: proper escape sequences for colors and logic"
git push origin main
