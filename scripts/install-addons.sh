#!/bin/bash
#==============================================================================
# mbcloud-system - install-addons.sh (ИСПРАВЛЕННАЯ ВЕРСИЯ)
# Установка дополнительных компонентов: Immich, MergerFS, мониторинг, бэкапы
# Версия: 2.1.0 (стабильная)
# 
# Использование:
#   sudo bash install-addons.sh --recommended    # Рекомендуемые компоненты
#   sudo bash install-addons.sh --all           # Все компоненты
#   sudo bash install-addons.sh --interactive   # Интерактивный выбор
#==============================================================================

set -euo pipefail  # Строгий режим: ошибка = выход

#------------------------------------------------------------------------------
# 🎨 КОНФИГУРАЦИЯ И ЦВЕТА (исправлено экранирование)
#------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Пути и настройки
REPO_URL="https://github.com/mibitok/mbcloud-system.git"
REPO_BRANCH="main"
REPO_PATH="${REPO_PATH:-/home/$SUDO_USER/mbcloud-system}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/mbcloud-install.log"
DATA_MOUNT="${DATA_MOUNT:-/DATA}"
MERGERFS_MOUNTS="${MERGERFS_MOUNTS:-/mnt/disk1:/mnt/disk2}"
IMMICH_DIR="${IMMICH_DIR:-/opt/immich}"

# Флаги установки (по умолчанию)
INSTALL_IMMICH="${INSTALL_IMMICH:-true}"
INSTALL_MERGERFS="${INSTALL_MERGERFS:-true}"
INSTALL_MONITORING="${INSTALL_MONITORING:-true}"
INSTALL_AUTOUPDATE="${INSTALL_AUTOUPDATE:-true}"
INSTALL_BACKUP="${INSTALL_BACKUP:-true}"
INSTALL_SAMBA="${INSTALL_SAMBA:-false}"

# Режим работы
MODE="${MODE:-interactive}"  # interactive, recommended, full, silent

#------------------------------------------------------------------------------
# 📝 ЛОГИРОВАНИЕ
#------------------------------------------------------------------------------
log() {
    echo -e "${BLUE}[ℹ]${NC} $1" | tee -a "$LOG_FILE"
}

log_ok() {
    echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1" | tee -a "$LOG_FILE"
}

log_err() {
    echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE" >&2
}

header() {
    echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"
}

#------------------------------------------------------------------------------
# 🔍 ПРОВЕРКА ПРАВИЛ И ЗАВИСИМОСТЕЙ
#------------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || { log_err "Запустите скрипт с sudo"; exit 1; }
}

check_os() {
    if ! grep -q "Raspberry Pi OS" /etc/os-release 2>/dev/null; then
        log_warn "Скрипт оптимизирован для Raspberry Pi OS"
        read -p "Продолжить? (y/N): " -n 1 -r || true
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || exit 1
    fi
}

check_disk_space() {
    local required_gb="${1:-10}"
    local available_gb=$(df -BG "$DATA_MOUNT" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
    available_gb=${available_gb:-0}
    
    if [[ $available_gb -lt $required_gb ]]; then
        log_warn "Недостаточно места: доступно ${available_gb}GB, требуется ${required_gb}GB"
        [[ "$MODE" == "silent" ]] && return 1
        read -p "Продолжить с риском? (y/N): " -n 1 -r || true
        echo
        [[ $REPLY =~ ^[Yy]$ ]] || return 1
    fi
    return 0
}

check_internet() {
    if ! ping -c 1 -W 3 github.com &>/dev/null; then
        log_err "Нет доступа к интернету. Проверьте соединение."
        return 1
    fi
    return 0
}

#------------------------------------------------------------------------------
# 📦 УПРАВЛЕНИЕ ПАКЕТАМИ
#------------------------------------------------------------------------------
install_packages() {
    local packages=("$@")
    log "Устанавливаем пакеты: ${packages[*]}"
    
    sudo apt update -qq 2>/dev/null || true
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            sudo apt install -y -qq "$pkg" 2>/dev/null || log_warn "Не удалось установить $pkg"
        fi
    done
}

#------------------------------------------------------------------------------
# 🔄 КЛОНОВАНИЕ РЕПОЗИТОРИЯ (надёжная версия)
#------------------------------------------------------------------------------
check_repo() {
    header "📦 Проверка репозитория"
    
    # Если уже в репозитории - используем текущий путь
    if [[ -f "$SCRIPT_DIR/../.git/config" ]]; then
        REPO_PATH="$(cd "$SCRIPT_DIR/.." && pwd)"
        log_ok "Работаем из локального репозитория: $REPO_PATH"
        return 0
    fi
    
    # Проверяем указанный путь
    if [[ -d "$REPO_PATH/.git" ]]; then
        log_ok "Репозиторий найден: $REPO_PATH"
        return 0
    fi
    
    # Пытаемся клонировать
    log "Клонируем репозиторий..."
    local clone_path="/home/$SUDO_USER/mbcloud-system"
    
    if git clone -b "$REPO_BRANCH" --depth 1 "$REPO_URL" "$clone_path" 2>/dev/null; then
        REPO_PATH="$clone_path"
        log_ok "Репозиторий клонирован: $REPO_PATH"
        return 0
    fi
    
    # Фолбэк: проверяем альтернативные пути
    for path in "/root/mbcloud-system" "/home/pi/mbcloud-system" "/opt/mbcloud-system"; do
        if [[ -d "$path/.git" ]]; then
            REPO_PATH="$path"
            log_ok "Репозиторий найден: $REPO_PATH"
            return 0
        fi
    done
    
    log_err "Не удалось получить репозиторий. Проверьте интернет и права доступа."
    return 1
}

#------------------------------------------------------------------------------
# 🐳 DOCKER INSTALLATION (без newgrp)
#------------------------------------------------------------------------------
install_docker_if_needed() {
    header "🐳 Проверка Docker"
    
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        log_ok "Docker уже установлен и работает"
        # Добавляем пользователя в группу docker (если не в ней)
        if ! groups "$SUDO_USER" | grep -q docker; then
            sudo usermod -aG docker "$SUDO_USER" 2>/dev/null || true
            log_warn "Пользователь добавлен в группу docker. Выйдите и войдите снова для применения."
        fi
        return 0
    fi
    
    log "Устанавливаем Docker..."
    
    # Метод 1: Официальный скрипт
    if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
        if sudo sh /tmp/get-docker.sh 2>&1 | tee -a "$LOG_FILE"; then
            sudo usermod -aG docker "$SUDO_USER" 2>/dev/null || true
            rm -f /tmp/get-docker.sh
            log_ok "Docker установлен через get.docker.com"
            log_warn "⚠️  Для работы docker без sudo: выйдите и войдите в систему заново"
            return 0
        fi
    fi
    
    # Метод 2: Через apt
    log "Пробуем установку через apt..."
    sudo apt update -qq
    if sudo apt install -y -qq docker.io docker-compose-plugin 2>/dev/null; then
        sudo usermod -aG docker "$SUDO_USER" 2>/dev/null || true
        sudo systemctl enable --now docker 2>/dev/null || true
        log_ok "Docker установлен через apt"
        return 0
    fi
    
    log_err "Не удалось установить Docker. Установите вручную: https://docs.docker.com/engine/install/"
    return 1
}

#------------------------------------------------------------------------------
# 💾 MERGERFS SETUP (БЕЗОПАСНАЯ ВЕРСИЯ С ВАЛИДАЦИЕЙ)
#------------------------------------------------------------------------------
setup_mergerfs() {
    [[ "$INSTALL_MERGERFS" = "false" && "$MODE" != "full" && "$MODE" != "recommended" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "💾 Настроить MergerFS объединение дисков?" || return 0

    header "💾 Настройка MergerFS"
    
    # ✅ Проверка 1: установлен ли mergerfs
    if ! command -v mergerfs &>/dev/null; then
        log "Устанавливаем mergerfs..."
        install_packages mergerfs || {
            log_err "Не удалось установить mergerfs"
            return 1
        }
    fi

    # ✅ Проверка 2: существуют ли точки монтирования дисков
    local IFS=':'
    read -ra DISKS <<< "$MERGERFS_MOUNTS"
    local missing_disks=()
    
    for disk in "${DISKS[@]}"; do
        if [[ ! -d "$disk" ]] && [[ ! -b "$disk" ]]; then
            missing_disks+=("$disk")
        fi
    done
    
    if [[ ${#missing_disks[@]} -gt 0 ]]; then
        log_warn "Не найдены диски: ${missing_disks[*]}"
        log "Создаём пустые директории как заглушки (настройте вручную позже)"
        for disk in "${missing_disks[@]}"; do
            sudo mkdir -p "$disk" 2>/dev/null || true
        done
        log_warn "⚠️  MergerFS будет работать в режиме ожидания. Настройте диски вручную."
    fi

    # ✅ Проверка 3: не добавлена ли уже запись в fstab
    if grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        log_ok "MergerFS уже настроен в /etc/fstab"
        return 0
    fi

    # ✅ Проверка 4: существует ли точка назначения
    sudo mkdir -p "$DATA_MOUNT"
    
    # ✅ Безопасное добавление в fstab с бэкапом и валидацией
    local fstab_backup="/etc/fstab.mbcloud.backup.$(date +%Y%m%d%H%M%S)"
    sudo cp /etc/fstab "$fstab_backup"
    
    log "Добавляем запись в /etc/fstab..."
    {
        echo ""
        echo "# mbcloud NAS - MergerFS pool (добавлено $(date '+%Y-%m-%d %H:%M'))"
        echo "# Оригинальный fstab сохранён: $fstab_backup"
        echo "${MERGERFS_MOUNTS} ${DATA_MOUNT} fuse.mergerfs defaults,allow_other,use_ino,category.create=epff,_netdev,failover 0 0"
    } | sudo tee -a /etc/fstab >/dev/null
    
    # ✅ Тестовое монтирование (без перезагрузки!)
    log "Тестируем конфигурацию монтирования..."
    if sudo mount -a --no-mtab 2>&1 | tee -a "$LOG_FILE" | grep -qi "error\|fail\|wrong"; then
        log_err "❌ Ошибка при тестовом монтировании!"
        log "Восстанавливаем оригинальный fstab..."
        sudo cp "$fstab_backup" /etc/fstab
        log_warn "⚠️  MergerFS НЕ активирован. Проверьте:"
        log "  1. Диски отформатированы и доступны"
        log "  2. Пути в MERGERFS_MOUNTS корректны"
        log "  3. Пакет mergerfs установлен"
        return 1
    else
        # Пробуем смонтировать (может потребовать перезагрузки для _netdev)
        if sudo mount -a 2>/dev/null; then
            log_ok "✅ MergerFS успешно смонтирован в $DATA_MOUNT"
            # Проверка прав доступа
            sudo chown -R "$SUDO_USER:$SUDO_USER" "$DATA_MOUNT" 2>/dev/null || true
        else
            log_warn "⚠️  MergerFS настроен, но требует перезагрузки для активации"
        fi
    fi
    
    # Очистка старого бэкапа (храним только последний)
    sudo find /etc -name "fstab.mbcloud.backup.*" -mtime +7 -delete 2>/dev/null || true
    
    return 0
}

#------------------------------------------------------------------------------
# 📸 IMMICH INSTALLATION
#------------------------------------------------------------------------------
setup_immich() {
    [[ "$INSTALL_IMMICH" = "false" && "$MODE" != "full" && "$MODE" != "recommended" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "📸 Установить Immich фото-сервер?" || return 0

    header "📸 Установка Immich"
    
    # Проверка зависимостей
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
        log_err "Docker Compose не найден. Установите Docker сначала."
        return 1
    fi
    
    # Создаём директорию
    sudo mkdir -p "$IMMICH_DIR"
    sudo chown "$SUDO_USER:$SUDO_USER" "$IMMICH_DIR"
    
    # Скачиваем официальные файлы Immich (если не существуют)
    cd "$IMMICH_DIR"
    if [[ ! -f "docker-compose.yml" ]]; then
        log "Скачиваем конфигурацию Immich..."
        curl -fsSL "https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml" -o docker-compose.yml 2>/dev/null || {
            # Фолбэк на локальный шаблон
            if [[ -f "$REPO_PATH/templates/immich/docker-compose.yml" ]]; then
                cp "$REPO_PATH/templates/immich/docker-compose.yml" docker-compose.yml
                log_ok "Использован локальный шаблон"
            else
                log_err "Не удалось получить docker-compose.yml для Immich"
                return 1
            fi
        }
    fi
    
    # Генерируем .env файл
    if [[ ! -f ".env" ]]; then
        log "Создаём конфигурацию .env..."
        cat > .env << 'EOF'
# Immich Configuration - Auto-generated by mbcloud-system
UPLOAD_LOCATION=/DATA/immich/library
DB_DATA_LOCATION=/DATA/immich/postgres
IMMICH_VERSION=release
DB_PASSWORD=mbcloud_secure_password_$(date +%s | sha256sum | head -c 16)
EOF
        # Генерируем уникальный пароль
        local db_pass=$(openssl rand -base64 16 2>/dev/null || echo "mbcloud_$(date +%s)")
        sed -i "s/mbcloud_secure_password_.*/$db_pass/" .env
        chmod 600 .env
        log_ok "Конфигурация создана. Пароль БД сохранён в .env"
    fi
    
    # Создаём директорию для фото
    sudo mkdir -p /DATA/immich/library /DATA/immich/postgres
    sudo chown -R "$SUDO_USER:$SUDO_USER" /DATA/immich
    
    # Запускаем Immich
    log "Запускаем Immich контейнеры..."
    if (docker compose up -d 2>&1 || docker-compose up -d 2>&1) | tee -a "$LOG_FILE"; then
        log_ok "✅ Immich запущен!"
        log "  → Веб-интерфейс: http://$(hostname -I | awk '{print $1}'):2283"
        log "  → Первоначальная настройка при первом входе"
        # Ждём немного для инициализации
        sleep 5
        if docker ps | grep -q immich-server; then
            log_ok "Контейнеры Immich работают"
        else
            log_warn "⚠️  Контейнеры Immich могут ещё инициализироваться. Проверьте: docker ps"
        fi
    else
        log_err "❌ Не удалось запустить Immich"
        log "Проверьте логи: docker compose logs"
        return 1
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# 📊 MONITORING SETUP (Grafana + Prometheus)
#------------------------------------------------------------------------------
setup_monitoring() {
    [[ "$INSTALL_MONITORING" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "📊 Установить мониторинг (Grafana/Prometheus)?" || return 0

    header "📊 Настройка мониторинга"
    
    local monitoring_dir="/opt/mbcloud-monitoring"
    sudo mkdir -p "$monitoring_dir"
    cd "$monitoring_dir"
    
    # Копируем конфиги из репозитория
    if [[ -d "$REPO_PATH/templates/monitoring" ]]; then
        cp -r "$REPO_PATH/templates/monitoring/"* . 2>/dev/null || true
        log_ok "Конфигурации мониторинга скопированы"
    else
        log_warn "Шаблоны мониторинга не найдены, используем базовые настройки"
        # Создаём минимальный docker-compose.yml
        cat > docker-compose.yml << 'EOF'
version: '3.8'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=mbcloud
    depends_on:
      - prometheus
    restart: unless-stopped

volumes:
  prometheus_data:
  grafana_data:
EOF
        # Базовый prometheus.yml
        cat > prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  - job_name: 'node'
    static_configs:
      - targets: ['host.docker.internal:9100']
EOF
    fi
    
    # Запускаем
    log "Запускаем сервисы мониторинга..."
    if (docker compose up -d 2>&1 || docker-compose up -d 2>&1) | tee -a "$LOG_FILE"; then
        log_ok "✅ Мониторинг запущен!"
        log "  → Grafana: http://$(hostname -I | awk '{print $1}'):3000 (admin/mbcloud)"
        log "  → Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
    else
        log_warn "⚠️  Не удалось запустить мониторинг. Проверьте порты и логи."
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# 🔄 AUTO-UPDATE SETUP
#------------------------------------------------------------------------------
setup_autoupdate() {
    [[ "$INSTALL_AUTOUPDATE" = "false" && "$MODE" != "full" && "$MODE" != "recommended" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "🔄 Настроить авто-обновление?" || return 0

    header "🔄 Настройка авто-обновления"
    
    local cron_file="/etc/cron.d/mbcloud-autoupdate"
    
    # Создаём скрипт обновления
    sudo mkdir -p /usr/local/bin
    cat > /usr/local/bin/mbcloud-update.sh << 'EOF'
#!/bin/bash
# mbcloud auto-update script
LOG="/var/log/mbcloud-update.log"
REPO="/home/pi/mbcloud-system"

echo "[$(date)] Starting update..." >> "$LOG"
cd "$REPO" || exit 1
git pull --quiet origin main >> "$LOG" 2>&1

# Перезапускаем сервисы если есть изменения
if docker compose ls 2>/dev/null | grep -q immich; then
    cd /opt/immich && docker compose pull --quiet && docker compose up -d --quiet-pull >> "$LOG" 2>&1
fi

echo "[$(date)] Update complete" >> "$LOG"
EOF
    sudo chmod +x /usr/local/bin/mbcloud-update.sh
    
    # Добавляем в cron (раз в сутки в 3:00)
    echo "0 3 * * * root /usr/local/bin/mbcloud-update.sh" | sudo tee "$cron_file" >/dev/null
    sudo chmod 644 "$cron_file"
    
    log_ok "✅ Авто-обновление настроено (ежедневно в 3:00)"
    log "  → Логи: /var/log/mbcloud-update.log"
    log "  → Принудительный запуск: sudo /usr/local/bin/mbcloud-update.sh"
    
    return 0
}

#------------------------------------------------------------------------------
# 💾 BACKUP SETUP
#------------------------------------------------------------------------------
setup_backup() {
    [[ "$INSTALL_BACKUP" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "💾 Настроить авто-бэкапы?" || return 0

    header "💾 Настройка резервного копирования"
    
    local backup_dir="/DATA/backups"
    local backup_script="/usr/local/bin/mbcloud-backup.sh"
    
    sudo mkdir -p "$backup_dir/immich" "$backup_dir/config"
    
    # Создаём скрипт бэкапа
    cat > "$backup_script" << EOF
#!/bin/bash
# mbcloud backup script
BACKUP_DIR="$backup_dir"
DATE=\$(date +%Y%m%d_%H%M%S)
LOG="/var/log/mbcloud-backup.log"

echo "[\$(date)] Starting backup..." >> "\$LOG"

# Бэкап Immich (если запущен)
if docker ps | grep -q immich-server; then
    echo "Backing up Immich database..." >> "\$LOG"
    docker exec immich_postgres pg_dumpall -c -U postgres > "\$BACKUP_DIR/immich/pg_backup_\$DATE.sql" 2>>"\$LOG"
fi

# Бэкап конфигураций
tar -czf "\$BACKUP_DIR/config/mbcloud_config_\$DATE.tar.gz" \
    /etc/fstab \
    /opt/immich/.env \
    /opt/mbcloud-monitoring 2>>"\$LOG" || true

# Удаляем бэкапы старше 7 дней
find "\$BACKUP_DIR" -name "*.sql" -mtime +7 -delete 2>/dev/null
find "\$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete 2>/dev/null

echo "[\$(date)] Backup complete" >> "\$LOG"
EOF
    sudo chmod +x "$backup_script"
    
    # Добавляем в cron (ежедневно в 4:00)
    echo "0 4 * * * root $backup_script" | sudo tee -a /etc/cron.d/mbcloud-autoupdate >/dev/null
    
    log_ok "✅ Авто-бэкапы настроены (ежедневно в 4:00)"
    log "  → Путь: $backup_dir"
    log "  → Логи: /var/log/mbcloud-backup.log"
    log "  → Принудительный запуск: sudo $backup_script"
    
    return 0
}

#------------------------------------------------------------------------------
# 🌐 SAMBA SETUP (опционально)
#------------------------------------------------------------------------------
setup_samba() {
    [[ "$INSTALL_SAMBA" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "false" "🌐 Настроить Samba общий доступ?" || return 0

    header "🌐 Настройка Samba"
    
    install_packages samba
    
    local samba_conf="/etc/samba/smb.conf"
    local backup_conf="$samba_conf.mbcloud.bak"
    
    # Бэкап оригинала
    [[ -f "$samba_conf" && ! -f "$backup_conf" ]] && sudo cp "$samba_conf" "$backup_conf"
    
    # Добавляем share для /DATA
    if ! grep -q "\[mbcloud-data\]" "$samba_conf" 2>/dev/null; then
        sudo bash -c "cat >> $samba_conf" << 'EOF'

[mbcloud-data]
    comment = mbcloud NAS Storage
    path = /DATA
    browseable = yes
    read only = no
    guest ok = no
    create mask = 0644
    directory mask = 0755
    force user = pi
EOF
        log_ok "Добавлен Samba share [mbcloud-data]"
    fi
    
    # Создаём пользователя Samba (если не существует)
    if ! smbpasswd -a "$SUDO_USER" &>/dev/null; then
        log "Установите пароль для Samba доступа пользователя $SUDO_USER:"
        sudo smbpasswd -a "$SUDO_USER"
    fi
    
    # Перезапускаем Samba
    sudo systemctl enable --now smbd nmbd 2>/dev/null || true
    
    log_ok "✅ Samba настроен"
    log "  → Доступ: \\\\$(hostname -I | awk '{print $1}')\\mbcloud-data"
    log "  → Пользователь: $SUDO_USER"
    
    return 0
}

#------------------------------------------------------------------------------
# ❓ ИНТЕРАКТИВНЫЙ ВЫБОР
#------------------------------------------------------------------------------
ask_confirm() {
    local default="${1:-false}"
    local question="${2:-Продолжить?}"
    
    [[ "$MODE" != "interactive" ]] && [[ "$default" == "true" ]] && return 0
    [[ "$MODE" != "interactive" ]] && return 1
    
    local prompt="${question} [Y/n]: "
    [[ "$default" == "false" ]] && prompt="${question} [y/N]: "
    
    read -p "$prompt" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    elif [[ $REPLY =~ ^[Nn]$ ]]; then
        return 1
    elif [[ -z $REPLY ]]; then
        [[ "$default" == "true" ]] && return 0 || return 1
    fi
    return 1
}

#------------------------------------------------------------------------------
# 🧪 HEALTH CHECK ПОСЛЕ УСТАНОВКИ
#------------------------------------------------------------------------------
post_install_health_check() {
    header "🧪 Проверка установки"
    
    local errors=0
    
    # Проверка Docker
    if docker info &>/dev/null; then
        log_ok "✓ Docker работает"
    else
        log_err "✗ Docker не отвечает"
        ((errors++))
    fi
    
    # Проверка MergerFS
    if grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
            log_ok "✓ MergerFS смонтирован: $DATA_MOUNT"
        else
            log_warn "⚠ MergerFS в fstab, но не смонтирован (требуется перезагрузка?)"
        fi
    fi
    
    # Проверка Immich
    if docker ps 2>/dev/null | grep -q immich-server; then
        log_ok "✓ Immich контейнеры работают"
    elif [[ -d "$IMMICH_DIR" ]]; then
        log_warn "⚠ Immich установлен, но контейнеры не запущены"
    fi
    
    # Проверка портов
    for port in 2283 3000 9090; do
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            log_ok "✓ Порт $port активен"
        fi
    done
    
    # Итог
    echo
    if [[ $errors -eq 0 ]]; then
        log_ok "🎉 Установка завершена успешно!"
    else
        log_warn "⚠️  Установка завершена с $errors предупреждениями. Проверьте логи выше."
    fi
    
    echo -e "\n${BOLD}Полезные команды:${NC}"
    echo "  • Проверка статуса:  docker ps"
    echo "  • Логи Immich:       docker compose logs -f (в /opt/immich)"
    echo "  • Перезапуск:        sudo reboot"
    echo "  • Диагностика:       $REPO_PATH/scripts/health-check.sh"
    echo
}

#------------------------------------------------------------------------------
# 🎯 MAIN
#------------------------------------------------------------------------------
main() {
    # Инициализация логирования
    exec > >(tee -a "$LOG_FILE") 2>&1
    
    echo -e "${BOLD}${GREEN}"
    cat << 'BANNER'
╔════════════════════════════════════════════╗
║  mbcloud-system - Addons Installer v2.1.0  ║
║  Домашний NAS на Raspberry Pi CM4          ║
╚════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
    
    # Парсинг аргументов
    case "${1:-}" in
        --recommended)
            MODE="recommended"
            INSTALL_SAMBA="false"
            INSTALL_MONITORING="false"  # Только essentials
            log "Режим: рекомендуемые компоненты (Immich + MergerFS + авто-обновление)"
            ;;
        --all|--full)
            MODE="full"
            log "Режим: все компоненты"
            ;;
        --silent)
            MODE="silent"
            INSTALL_IMMICH="${INSTALL_IMMICH:-true}"
            ;;
        --interactive|-i|"")
            MODE="interactive"
            log "Режим: интерактивный выбор"
            ;;
        --help|-h)
            echo "Использование: $0 [опции]"
            echo "  --recommended   Установить рекомендуемые компоненты"
            echo "  --all           Установить все компоненты"
            echo "  --interactive   Интерактивный выбор (по умолчанию)"
            echo "  --silent        Тихая установка с настройками по умолчанию"
            exit 0
            ;;
        *)
            log_warn "Неизвестный параметр: $1. Используем интерактивный режим."
            MODE="interactive"
            ;;
    esac
    
    # Предварительные проверки
    check_root
    check_os
    check_internet || { log_warn "Продолжаем без проверки обновлений"; }
    check_repo || exit 1
    check_disk_space 20  # Минимум 20GB для Immich
    
    # Установка базовых зависимостей
    install_packages curl wget git apt-transport-https ca-certificates gnupg lsb-release
    
    # Установка Docker (если нужно)
    install_docker_if_needed || {
        log_err "Критическая ошибка: Docker не установлен. Прерываем установку."
        exit 1
    }
    
    # Установка компонентов
    setup_mergerfs || true  # Не критично, продолжаем
    setup_immich || true
    setup_monitoring || true
    setup_autoupdate || true
    setup_backup || true
    setup_samba || true
    
    # Финальная проверка
    post_install_health_check
    
    log_ok "📄 Полный лог установки: $LOG_FILE"
    
    # Предупреждение о перезагрузке для fstab
    if grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        echo -e "\n${YELLOW}💡 Рекомендуется перезагрузить систему для полной активации MergerFS:${NC}"
        echo "  sudo reboot"
    fi
}

# Запуск
main "$@"
