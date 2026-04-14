#!/bin/bash
#==============================================================================
# mbcloud-system - install-addons.sh
# Установка дополнительных компонентов: Immich, MergerFS, мониторинг, бэкапы
# Версия: 2.1.1 (HOTFIX - стабильная)
# 
# Использование:
#   sudo bash install-addons.sh --recommended    # Рекомендуемые компоненты
#   sudo bash install-addons.sh --all           # Все компоненты  
#   sudo bash install-addons.sh --interactive   # Интерактивный выбор
#   sudo bash install-addons.sh --offline       # Установка без клонирования
#==============================================================================

# ✅ Безопасный режим: без -u чтобы не падало на пустых переменных при pipe-запуске
set -eo pipefail

#------------------------------------------------------------------------------
# 🎨 КОНФИГУРАЦИЯ И ЦВЕТА
#------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

#------------------------------------------------------------------------------
# 👤 НАДЁЖНОЕ ОПРЕДЕЛЕНИЕ ПОЛЬЗОВАТЕЛЯ
#------------------------------------------------------------------------------
get_current_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    elif [[ -n "${USER:-}" ]]; then
        echo "$USER"
    elif [[ -n "${LOGNAME:-}" ]]; then
        echo "$LOGNAME"
    else
        whoami 2>/dev/null || getent passwd "$(id -u)" | cut -d: -f1 || echo "root"
    fi
}
CURRENT_USER="$(get_current_user)"

#------------------------------------------------------------------------------
# 📁 ПУТИ И НАСТРОЙКИ
#------------------------------------------------------------------------------
REPO_URL="https://github.com/mibitok/mbcloud-system.git"
REPO_BRANCH="main"
REPO_PATH="${REPO_PATH:-/home/$CURRENT_USER/mbcloud-system}"
LOG_FILE="/var/log/mbcloud-install.log"
DATA_MOUNT="${DATA_MOUNT:-/DATA}"
MERGERFS_MOUNTS="${MERGERFS_MOUNTS:-/mnt/disk1:/mnt/disk2}"
IMMICH_DIR="${IMMICH_DIR:-/opt/immich}"
OFFLINE_MODE="${OFFLINE_MODE:-false}"

# Флаги установки
INSTALL_IMMICH="${INSTALL_IMMICH:-true}"
INSTALL_MERGERFS="${INSTALL_MERGERFS:-true}"
INSTALL_MONITORING="${INSTALL_MONITORING:-true}"
INSTALL_AUTOUPDATE="${INSTALL_AUTOUPDATE:-true}"
INSTALL_BACKUP="${INSTALL_BACKUP:-true}"
INSTALL_SAMBA="${INSTALL_SAMBA:-false}"
MODE="${MODE:-interactive}"

#------------------------------------------------------------------------------
# 📝 ЛОГИРОВАНИЕ
#------------------------------------------------------------------------------
log() { echo -e "${BLUE}[ℹ]${NC} $1" | tee -a "$LOG_FILE"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1" | tee -a "$LOG_FILE"; }
log_err() { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE" >&2; }

header() {
    echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"
}

#------------------------------------------------------------------------------
# 🔍 ПРОВЕРКИ
#------------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || { log_err "Запустите скрипт с sudo"; exit 1; }
}

check_os() {
    if ! grep -qi "raspberry\|debian" /etc/os-release 2>/dev/null; then
        log_warn "Скрипт оптимизирован для Raspberry Pi OS / Debian"
        [[ "$MODE" == "silent" ]] && return 0
        read -p "Продолжить? (y/N): " -n 1 -r || true; echo
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    fi
}

check_internet() {
    if ! timeout 5 ping -c 1 8.8.8.8 &>/dev/null; then
        log_warn "Нет доступа к интернету"
        return 1
    fi
    return 0
}

check_disk_space() {
    local required_gb="${1:-10}"
    local available_gb
    available_gb=$(df -BG "$DATA_MOUNT" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G') || available_gb=0
    if [[ $available_gb -lt $required_gb ]]; then
        log_warn "Мало места: доступно ${available_gb}GB, нужно ${required_gb}GB"
        [[ "$MODE" == "silent" ]] && return 1
        read -p "Продолжить с риском? (y/N): " -n 1 -r || true; echo
        [[ $REPLY =~ ^[Yy]$ ]] || return 1
    fi
    return 0
}

#------------------------------------------------------------------------------
# 📦 УСТАНОВКА ПАКЕТОВ
#------------------------------------------------------------------------------
install_packages() {
    local packages=("$@")
    log "Устанавливаем: ${packages[*]}"
    apt update -qq 2>/dev/null || true
    for pkg in "${packages[@]}"; do
        dpkg -l | grep -q "^ii  $pkg " || apt install -y -qq "$pkg" 2>/dev/null || log_warn "Не установлен: $pkg"
    done
}

#------------------------------------------------------------------------------
# 🔄 ПРОВЕРКА/КЛОНОВАНИЕ РЕПОЗИТОРИЯ
#------------------------------------------------------------------------------
check_repo() {
    header "📦 Проверка репозитория"
    
    # Проверка git
    if ! command -v git &>/dev/null; then
        log "Устанавливаем git..."
        install_packages git || { log_err "git не установлен"; return 1; }
    fi
    
    # Если уже в репозитории
    local script_parent="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")/.." 2>/dev/null && pwd 2>/dev/null)" || script_parent=""
    if [[ -n "$script_parent" && -f "$script_parent/.git/config" ]]; then
        REPO_PATH="$script_parent"
        log_ok "Локальный репозиторий: $REPO_PATH"
        return 0
    fi
    
    # Проверка указанного пути
    [[ -d "$REPO_PATH/.git" ]] && { log_ok "Репозиторий: $REPO_PATH"; return 0; }
    
    # Offline режим
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        log_warn "Offline режим: пропускаем клонирование"
        return 1
    fi
    
    # Проверка соединения с GitHub
    if ! timeout 10 git ls-remote "$REPO_URL" &>/dev/null; then
        log_warn "Нет доступа к GitHub"
        # Поиск локальных копий
        for path in "/root/mbcloud-system" "/home/pi/mbcloud-system" "/opt/mbcloud-system"; do
            [[ -d "$path/.git" || -f "$path/scripts/install-addons.sh" ]] && { REPO_PATH="$path"; log_ok "Найдено: $REPO_PATH"; return 0; }
        done
        log_err "Репозиторий не найден. Установите вручную: git clone $REPO_URL $REPO_PATH"
        return 1
    fi
    
    # Клонирование
    log "Клонируем репозиторий..."
    local clone_path="/home/$CURRENT_USER/mbcloud-system"
    mkdir -p "$(dirname "$clone_path")"
    if git clone -b "$REPO_BRANCH" --depth 1 "$REPO_URL" "$clone_path" 2>&1 | tee -a "$LOG_FILE"; then
        REPO_PATH="$clone_path"
        log_ok "Клонировано: $REPO_PATH"
        return 0
    fi
    log_err "Ошибка клонирования"
    return 1
}

#------------------------------------------------------------------------------
# 🐳 DOCKER
#------------------------------------------------------------------------------
install_docker_if_needed() {
    header "🐳 Проверка Docker"
    
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        log_ok "Docker работает"
        groups "$CURRENT_USER" | grep -q docker || usermod -aG docker "$CURRENT_USER" 2>/dev/null || true
        return 0
    fi
    
    log "Устанавливаем Docker..."
    
    # Метод 1: get.docker.com
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
        if sh /tmp/get-docker.sh 2>&1 | tee -a "$LOG_FILE"; then
            usermod -aG docker "$CURRENT_USER" 2>/dev/null || true
            rm -f /tmp/get-docker.sh
            log_ok "Docker установлен"
            log_warn "💡 Выйдите и войдите снова для работы docker без sudo"
            return 0
        fi
    fi
    
    # Метод 2: apt
    log "Пробуем через apt..."
    apt update -qq
    if apt install -y -qq docker.io docker-compose-plugin 2>/dev/null; then
        usermod -aG docker "$CURRENT_USER" 2>/dev/null || true
        systemctl enable --now docker 2>/dev/null || true
        log_ok "Docker установлен через apt"
        return 0
    fi
    
    log_err "Не удалось установить Docker"
    return 1
}

#------------------------------------------------------------------------------
# 💾 MERGERFS (БЕЗОПАСНО)
#------------------------------------------------------------------------------
setup_mergerfs() {
    [[ "$INSTALL_MERGERFS" = "false" && "$MODE" != "full" && "$MODE" != "recommended" ]] && return 0
    [[ "$MODE" != "interactive" ]] || { read -p "💾 Настроить MergerFS? (Y/n): " -n 1 -r || true; echo; [[ ! $REPLY =~ ^[Nn]$ ]]; } || return 0

    header "💾 Настройка MergerFS"
    
    # Установка mergerfs
    if ! command -v mergerfs &>/dev/null; then
        log "Устанавливаем mergerfs..."
        install_packages mergerfs || { log_err "Ошибка установки mergerfs"; return 1; }
    fi

    # Проверка дисков
    local IFS=':'; read -ra DISKS <<< "$MERGERFS_MOUNTS"
    local missing=()
    for disk in "${DISKS[@]}"; do
        [[ -d "$disk" || -b "$disk" ]] || missing+=("$disk")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Не найдены: ${missing[*]}"
        for d in "${missing[@]}"; do mkdir -p "$d" 2>/dev/null || true; done
        log_warn "Созданы заглушки — настройте диски вручную"
    fi

    # Проверка fstab
    grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null && { log_ok "MergerFS уже в fstab"; return 0; }

    mkdir -p "$DATA_MOUNT"
    
    # Бэкап fstab
    local backup="/etc/fstab.mbcloud.$(date +%Y%m%d%H%M%S)"
    cp /etc/fstab "$backup"
    
    # Добавление записи
    { echo ""; echo "# mbcloud MergerFS $(date '+%Y-%m-%d')"; echo "${MERGERFS_MOUNTS} ${DATA_MOUNT} fuse.mergerfs defaults,allow_other,use_ino,category.create=epff,_netdev,failover 0 0"; } >> /etc/fstab
    
    # Тест монтирования
    if mount -a --no-mtab 2>&1 | grep -qi "error\|fail"; then
        log_err "Ошибка монтирования! Восстанавливаем fstab..."
        cp "$backup" /etc/fstab
        log_warn "MergerFS не активирован — проверьте диски"
        return 1
    fi
    
    mount -a 2>/dev/null && log_ok "MergerFS смонтирован: $DATA_MOUNT" || log_warn "Требуется reboot"
    chown -R "$CURRENT_USER:$CURRENT_USER" "$DATA_MOUNT" 2>/dev/null || true
    
    # Очистка старых бэкапов
    find /etc -name "fstab.mbcloud.*" -mtime +7 -delete 2>/dev/null || true
    return 0
}

#------------------------------------------------------------------------------
# 📸 IMMICH
#------------------------------------------------------------------------------
setup_immich() {
    [[ "$INSTALL_IMMICH" = "false" && "$MODE" != "full" && "$MODE" != "recommended" ]] && return 0
    [[ "$MODE" != "interactive" ]] || { read -p "📸 Установить Immich? (Y/n): " -n 1 -r || true; echo; [[ ! $REPLY =~ ^[Nn]$ ]]; } || return 0

    header "📸 Установка Immich"
    
    command -v docker-compose &>/dev/null || docker compose version &>/dev/null || { log_err "Docker Compose не найден"; return 1; }
    
    mkdir -p "$IMMICH_DIR"; chown "$CURRENT_USER:$CURRENT_USER" "$IMMICH_DIR"
    cd "$IMMICH_DIR"
    
    # docker-compose.yml
    if [[ ! -f "docker-compose.yml" ]]; then
        log "Скачиваем docker-compose.yml..."
        curl -fsSL "https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml" -o docker-compose.yml 2>/dev/null || {
            [[ -f "$REPO_PATH/templates/immich/docker-compose.yml" ]] && cp "$REPO_PATH/templates/immich/docker-compose.yml" docker-compose.yml || {
                log_err "Не удалось получить docker-compose.yml"; return 1
            }
        }
    fi
    
    # .env файл
    if [[ ! -f ".env" ]]; then
        log "Создаём .env..."
        local db_pass=$(openssl rand -base64 16 2>/dev/null || echo "mbcloud_$(date +%s)")
        cat > .env << EOF
# Immich - mbcloud auto-generated
UPLOAD_LOCATION=/DATA/immich/library
DB_DATA_LOCATION=/DATA/immich/postgres
IMMICH_VERSION=release
DB_PASSWORD=$db_pass
EOF
        chmod 600 .env
        log_ok "Конфиг создан, пароль БД в .env"
    fi
    
    # Директории
    mkdir -p /DATA/immich/library /DATA/immich/postgres
    chown -R "$CURRENT_USER:$CURRENT_USER" /DATA/immich
    
    # Запуск
    log "Запускаем Immich..."
    if (docker compose up -d 2>&1 || docker-compose up -d 2>&1) | tee -a "$LOG_FILE"; then
        log_ok "✅ Immich запущен!"
        log "  → http://$(hostname -I | awk '{print $1}'):2283"
        sleep 3
        docker ps 2>/dev/null | grep -q immich-server && log_ok "Контейнеры работают" || log_warn "Контейнеры инициализируются..."
    else
        log_err "Ошибка запуска Immich. Проверьте: docker compose logs"
        return 1
    fi
    return 0
}

#------------------------------------------------------------------------------
# 📊 MONITORING
#------------------------------------------------------------------------------
setup_monitoring() {
    [[ "$INSTALL_MONITORING" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || { read -p "📊 Установить мониторинг? (y/N): " -n 1 -r || true; echo; [[ $REPLY =~ ^[Yy]$ ]]; } || return 0

    header "📊 Мониторинг (Grafana/Prometheus)"
    
    local dir="/opt/mbcloud-monitoring"; mkdir -p "$dir"; cd "$dir"
    
    if [[ -d "$REPO_PATH/templates/monitoring" ]]; then
        cp -r "$REPO_PATH/templates/monitoring/"* . 2>/dev/null || true
        log_ok "Конфиги скопированы"
    else
        log_warn "Шаблоны не найдены, создаём базовые"
        cat > docker-compose.yml << 'EOF'
version: '3.8'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports: ["9090:9090"]
    volumes: ["./prometheus.yml:/etc/prometheus/prometheus.yml","prometheus_data:/prometheus"]
    command: ['--config.file=/etc/prometheus/prometheus.yml','--storage.tsdb.path=/prometheus']
    restart: unless-stopped
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports: ["3000:3000"]
    volumes: ["grafana_data:/var/lib/grafana"]
    environment: ["GF_SECURITY_ADMIN_USER=admin","GF_SECURITY_ADMIN_PASSWORD=mbcloud"]
    depends_on: [prometheus]
    restart: unless-stopped
volumes: {prometheus_data:, grafana_data:}
EOF
        cat > prometheus.yml << 'EOF'
global: {scrape_interval: 15s}
scrape_configs:
  - job_name: prometheus
    static_configs: [{targets: [localhost:9090]}]
EOF
    fi
    
    log "Запускаем..."
    (docker compose up -d 2>&1 || docker-compose up -d 2>&1) | tee -a "$LOG_FILE" && \
        log_ok "✅ Мониторинг: http://$(hostname -I | awk '{print $1}'):3000 (admin/mbcloud)" || \
        log_warn "⚠️ Ошибка запуска мониторинга"
    return 0
}

#------------------------------------------------------------------------------
# 🔄 AUTO-UPDATE
#------------------------------------------------------------------------------
setup_autoupdate() {
    [[ "$INSTALL_AUTOUPDATE" = "false" && "$MODE" != "full" && "$MODE" != "recommended" ]] && return 0
    [[ "$MODE" != "interactive" ]] || { read -p "🔄 Настроить авто-обновление? (Y/n): " -n 1 -r || true; echo; [[ ! $REPLY =~ ^[Nn]$ ]]; } || return 0

    header "🔄 Авто-обновление"
    
    cat > /usr/local/bin/mbcloud-update.sh << 'EOF'
#!/bin/bash
LOG="/var/log/mbcloud-update.log"
REPO="/home/pi/mbcloud-system"
echo "[$(date)] Update start" >> "$LOG"
cd "$REPO" 2>/dev/null && git pull --quiet origin main >> "$LOG" 2>&1
[[ -d /opt/immich ]] && cd /opt/immich && (docker compose pull --quiet && docker compose up -d --quiet-pull) >> "$LOG" 2>&1
echo "[$(date)] Update done" >> "$LOG"
EOF
    chmod +x /usr/local/bin/mbcloud-update.sh
    echo "0 3 * * * root /usr/local/bin/mbcloud-update.sh" | tee /etc/cron.d/mbcloud-autoupdate >/dev/null
    chmod 644 /etc/cron.d/mbcloud-autoupdate
    
    log_ok "✅ Авто-обновление: ежедневно в 3:00"
    log "  → Лог: /var/log/mbcloud-update.log"
    log "  → Вручную: sudo /usr/local/bin/mbcloud-update.sh"
    return 0
}

#------------------------------------------------------------------------------
# 💾 BACKUP
#------------------------------------------------------------------------------
setup_backup() {
    [[ "$INSTALL_BACKUP" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || { read -p "💾 Настроить авто-бэкапы? (y/N): " -n 1 -r || true; echo; [[ $REPLY =~ ^[Yy]$ ]]; } || return 0

    header "💾 Авто-бэкапы"
    
    local backup_dir="/DATA/backups"
    mkdir -p "$backup_dir/immich" "$backup_dir/config"
    
    cat > /usr/local/bin/mbcloud-backup.sh << EOF
#!/bin/bash
BACKUP_DIR="$backup_dir"
DATE=\$(date +%Y%m%d_%H%M%S)
LOG="/var/log/mbcloud-backup.log"
echo "[\$(date)] Backup start" >> "\$LOG"
docker ps 2>/dev/null | grep -q immich-server && docker exec immich_postgres pg_dumpall -c -U postgres > "\$BACKUP_DIR/immich/pg_\$DATE.sql" 2>>"\$LOG" || true
tar -czf "\$BACKUP_DIR/config/config_\$DATE.tar.gz" /etc/fstab /opt/immich/.env 2>>"\$LOG" || true
find "\$BACKUP_DIR" -mtime +7 -delete 2>/dev/null
echo "[\$(date)] Backup done" >> "\$LOG"
EOF
    chmod +x /usr/local/bin/mbcloud-backup.sh
    echo "0 4 * * * root /usr/local/bin/mbcloud-backup.sh" | tee -a /etc/cron.d/mbcloud-autoupdate >/dev/null
    
    log_ok "✅ Бэкапы: ежедневно в 4:00 → $backup_dir"
    log "  → Лог: /var/log/mbcloud-backup.log"
    log "  → Вручную: sudo /usr/local/bin/mbcloud-backup.sh"
    return 0
}

#------------------------------------------------------------------------------
# 🌐 SAMBA
#------------------------------------------------------------------------------
setup_samba() {
    [[ "$INSTALL_SAMBA" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || { read -p "🌐 Настроить Samba? (y/N): " -n 1 -r || true; echo; [[ $REPLY =~ ^[Yy]$ ]]; } || return 0

    header "🌐 Samba"
    install_packages samba
    
    grep -q "\[mbcloud-data\]" /etc/samba/smb.conf 2>/dev/null || {
        cat >> /etc/samba/smb.conf << EOF

[mbcloud-data]
    comment = mbcloud NAS
    path = $DATA_MOUNT
    browseable = yes
    read only = no
    guest ok = no
    create mask = 0644
    directory mask = 0755
    force user = $CURRENT_USER
EOF
        log_ok "Share [mbcloud-data] добавлен"
    }
    
    smbpasswd -a "$CURRENT_USER" 2>/dev/null || { log "Установите пароль Samba для $CURRENT_USER"; smbpasswd -a "$CURRENT_USER"; }
    systemctl enable --now smbd nmbd 2>/dev/null || true
    
    log_ok "✅ Samba: \\\\$(hostname -I | awk '{print $1}')\\mbcloud-data"
    return 0
}

#------------------------------------------------------------------------------
# ❓ ИНТЕРАКТИВНЫЙ ВЫБОР (с поддержкой кириллицы)
#------------------------------------------------------------------------------
ask_confirm() {
    local default="${1:-false}" question="${2:-Продолжить?}"
    [[ "$MODE" != "interactive" ]] && [[ "$default" == "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] && return 1
    
    local prompt="[Y/n]: "; [[ "$default" == "false" ]] && prompt="[y/N]: "
    read -p "$question $prompt" -n 1 -r 2>/dev/null || true; echo
    
    # Поддержка y/Y/n/N и кириллицы у/н
    case "$REPLY" in
        [YyУу]) return 0 ;;
        [NnНн]|"") [[ "$default" == "true" ]] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

#------------------------------------------------------------------------------
# 🧪 HEALTH CHECK
#------------------------------------------------------------------------------
post_install_check() {
    header "🧪 Проверка установки"
    local err=0
    
    docker info &>/dev/null && log_ok "✓ Docker" || { log_err "✗ Docker"; ((err++)); }
    grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null && mountpoint -q "$DATA_MOUNT" 2>/dev/null && log_ok "✓ MergerFS: $DATA_MOUNT"
    docker ps 2>/dev/null | grep -q immich-server && log_ok "✓ Immich работает"
    
    for port in 2283 3000 9090; do
        ss -tlnp 2>/dev/null | grep -q ":$port " && log_ok "✓ Порт $port"
    done
    
    echo
    [[ $err -eq 0 ]] && log_ok "🎉 Установка успешна!" || log_warn "⚠️ Завершено с $err предупреждениями"
    
    echo -e "\n${BOLD}Команды:${NC}"
    echo "  • docker ps"
    echo "  • cd /opt/immich && docker compose logs -f"
    echo "  • sudo reboot"
    echo "  • $REPO_PATH/scripts/health-check.sh"
}

#------------------------------------------------------------------------------
# 🎯 MAIN
#------------------------------------------------------------------------------
main() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    
    echo -e "${BOLD}${GREEN}"
    cat << 'BANNER'
╔════════════════════════════════════════════╗
║  mbcloud-system - Addons Installer v2.1.1  ║
║  Домашний NAS на Raspberry Pi CM4          ║
╚════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    
    # Парсинг аргументов
    case "${1:-}" in
        --recommended) MODE="recommended"; INSTALL_SAMBA="false"; INSTALL_MONITORING="false"; log "Режим: рекомендуемые" ;;
        --all|--full) MODE="full"; log "Режим: все компоненты" ;;
        --offline) OFFLINE_MODE="true"; log "Режим: offline" ;;
        --silent) MODE="silent" ;;
        --help|-h) echo "Использование: $0 [--recommended|--all|--offline|--silent]"; exit 0 ;;
        *) MODE="interactive"; log "Режим: интерактивный" ;;
    esac
    
    # Проверки
    check_root
    check_os
    check_internet || log_warn "Продолжаем без проверки обновлений"
    check_repo || { [[ "$OFFLINE_MODE" == "true" ]] || exit 1; }
    check_disk_space 20
    
    # Зависимости
    install_packages curl wget git apt-transport-https ca-certificates
    
    # Docker
    install_docker_if_needed || { log_err "Docker критичен. Прерываем."; exit 1; }
    
    # Компоненты
    setup_mergerfs || true
    setup_immich || true
    setup_monitoring || true
    setup_autoupdate || true
    setup_backup || true
    setup_samba || true
    
    # Финал
    post_install_check
    log_ok "📄 Лог: $LOG_FILE"
    
    grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null && {
        echo -e "\n${YELLOW}💡 Рекомендуется: sudo reboot${NC}"
    }
}

# Запуск
main "$@"
