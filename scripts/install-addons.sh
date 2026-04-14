#!/bin/bash
#===============================================================================
# mbcloud NAS - Установка дополнительных компонентов (v1.2)
# Использование:
#   • Интерактивно:  curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/install-addons.sh | sudo bash
#   • Рекомендуемо:  ... | sudo bash -s -- --recommended
#   • Только Immich: ... | sudo bash -s -- --immich
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
SKIP_TELEGRAM=true  # По умолчанию пропускаем Telegram
SKIP_MONITORING=true
SKIP_PROXY=true
SKIP_BACKUP=true
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
    echo -e "${CYAN}${BOLD}║  mbcloud NAS - Addons Installer v1.2 ║${NC}"
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
    if [ -d "$REPO_PATH/.git" ]; then
        log_ok "Репозиторий уже существует: $REPO_PATH"
        return 0
    fi
    log "Клонируем репозиторий..."
    git clone -b "$REPO_BRANCH" "https://github.com/mibitok/mbcloud-system.git" "$REPO_PATH" 2>/dev/null || {
        log_warn "Не удалось клонировать — используем базовые настройки"
        REPO_PATH="/home/$USER/mbcloud-system"
        mkdir -p "$REPO_PATH"/{docker,scripts,display/fonts}
    }
}

install_docker_if_needed() {
    if ! command -v docker &>/dev/null; then
        log "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null && \
        sudo sh /tmp/get-docker.sh 2>/dev/null && {
            sudo usermod -aG docker "$USER" 2>/dev/null
            log_ok "Docker установлен"
        } || {
            sudo apt install -y -qq docker.io docker-compose-plugin 2>/dev/null && log_ok "Docker установлен через apt"
        }
        rm -f /tmp/get-docker.sh
    else
        log_ok "Docker уже установлен"
    fi
    # Применяем группу без перезагрузки
    newgrp docker 2>/dev/null || true
}

ask_confirm() {
    [[ "$MODE" != "interactive" ]] && return $([ "$1" = "true" ] && echo 0 || echo 1)
    read -p "$2 (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

#===============================================================================
# 🐳 IMMICH (с созданием файлов)
#===============================================================================

install_immich() {
    [[ "$INSTALL_IMMICH" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "🐳 Установить Immich?" || return 0
    
    header "🐳 Установка Immich"
    log "Immich — само-хостимый сервис для синхронизации фото."
    
    install_docker_if_needed
    
    # Проверяем место
    local free=$(df -BG "$DATA_MOUNT" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
    if [[ -n "$free" && "$free" -lt 10 ]]; then
        log_warn "Мало места на $DATA_MOUNT: ${free}GB (нужно минимум 10 ГБ)"
        [[ "$MODE" = "interactive" ]] && { read -p "Продолжить? (y/N): " -n 1 -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && return 0; }
    fi
    
    log "Настраиваем Immich..."
    mkdir -p "$DOCKER_DIR"
    
    # Создаём .env с ВСЕМИ переменными
    cat > "$DOCKER_DIR/.env" << 'ENVEOF'
# Immich Environment Variables - mbcloud NAS
DB_PASSWORD=mbcloud_immich_secure_password_2026
DB_USERNAME=immich
DB_DATABASE_NAME=immich
DB_DATA_LOCATION=/DATA/immich-postgres
UPLOAD_LOCATION=/DATA/immich-upload
LIBRARY_LOCATION=/DATA/immich-library
TZ=Europe/Moscow
MACHINE_LEARNING_MODEL_NAME=ViT-B-32__openai
TRASH_DAYS=30
ENVEOF
    
    # Генерируем случайный пароль для безопасности
    local new_pass=$(openssl rand -hex 16 2>/dev/null || echo "mbcloud_$(date +%s)")
    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$new_pass/" "$DOCKER_DIR/.env"
    chown "$USER:$USER" "$DOCKER_DIR/.env"
    log_ok "Файл .env создан"
    
    # Создаём docker-compose.yml (простая версия без переменных в volumes)
    cat > "$DOCKER_DIR/docker-compose.yml" << 'COMPOSEOF'
services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:release
    volumes:
      - /DATA/immich-upload:/usr/src/app/upload
      - /DATA/immich-library:/usr/src/app/library
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - 2283:2283
    depends_on:
      - redis
      - database
    restart: always
    healthcheck:
      test: wget --no-verbose --tries=1 --spider http://localhost:2283/api/server-info/ping || exit 1
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:release
    volumes:
      - ./model-cache:/cache
    env_file:
      - .env
    restart: always
    depends_on:
      - database

  redis:
    container_name: immich_redis
    image: redis:6.2-alpine
    restart: always
    healthcheck:
      test: redis-cli ping || exit 1
      interval: 30s
      timeout: 10s
      retries: 5

  database:
    container_name: immich_postgres
    image: tensorchord/pgvecto-rs:pg14-v0.2.0
    environment:
      POSTGRES_PASSWORD: mbcloud_immich_secure_password_2026
      POSTGRES_USER: immich
      POSTGRES_DB: immich
    volumes:
      - /DATA/immich-postgres:/var/lib/postgresql/data
    restart: always
    healthcheck:
      test: pg_isready -U immich -d immich || exit 1
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    command: [postgres, -c, shared_preload_libraries=vectors.so, -c, logging_collector=on]
COMPOSEOF
    
    # Заменяем пароль в docker-compose.yml на сгенерированный
    sed -i "s/mbcloud_immich_secure_password_2026/$new_pass/g" "$DOCKER_DIR/docker-compose.yml"
    
    # Создаём папки и исправляем права
    for dir in upload library postgres redis; do
        sudo mkdir -p "$DATA_MOUNT/immich-$dir"
    done
    sudo chown -R 999:999 "$DATA_MOUNT/immich-postgres" 2>/dev/null || true
    sudo chown -R "$USER:$USER" "$DATA_MOUNT/immich-upload" "$DATA_MOUNT/immich-library" "$DOCKER_DIR/model-cache" 2>/dev/null || true
    mkdir -p "$DOCKER_DIR/model-cache"
    
    log_ok "Папки созданы, права настроены"
    
    # Запускаем
    log "Запускаем Immich (может занять 5-15 минут на скачивание образов)..."
    cd "$DOCKER_DIR"
    
    # Пробуем запустить без sudo (если пользователь в группе docker)
    if docker compose up -d 2>&1 | tee /tmp/immich.log; then
        log_ok "Immich запущен! 🌐 http://$(hostname -I | awk '{print $1}'):2283"
        log "📱 Приложение: укажите тот же адрес, первый пользователь = админ"
    else
        # Пробуем с sudo и полным путём
        log_warn "Пробуем с sudo..."
        if sudo docker compose -f "$DOCKER_DIR/docker-compose.yml" up -d 2>&1 | tee -a /tmp/immich.log; then
            log_ok "Immich запущен (через sudo)! 🌐 http://$(hostname -I | awk '{print $1}'):2283"
        else
            log_err "Ошибка запуска — проверьте: docker compose logs -f"
            log "Или: sudo docker compose -f $DOCKER_DIR/docker-compose.yml logs -f"
        fi
    fi
    
    # Алиас для удобства
    grep -q "alias immich=" ~/.bashrc 2>/dev/null || echo "alias immich='cd $DOCKER_DIR && docker compose'" >> ~/.bashrc
    log "Добавлен алиас: ${BLUE}immich${NC}"
}

#===============================================================================
# 💾 MERGERFS
#===============================================================================

setup_mergerfs() {
    [[ "$INSTALL_MERGERFS" = "false" && "$MODE" != "full" ]] && return 0
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
# 🔄 АВТО-ОБНОВЛЕНИЕ
#===============================================================================

setup_auto_update() {
    [[ "$INSTALL_AUTOUPDATE" = "false" && "$MODE" != "full" ]] && return 0
    [[ "$MODE" != "interactive" ]] || ask_confirm "true" "🔄 Включить авто-обновление?" || return 0
    
    header "🔄 Настройка авто-обновления"
    
    dpkg -l | grep -q unattended-upgrades 2>/dev/null || sudo apt install -y -qq unattended-upgrades 2>/dev/null || true
    
    cat > "$REPO_PATH/scripts/update-mbcloud.sh" << 'EOF'
#!/bin/bash
REPO_PATH="${REPO_PATH:-/home/${SUDO_USER:-$(whoami)}/mbcloud-system}"
cd "$REPO_PATH" || exit 1
git pull -q 2>/dev/null && git diff --name-only HEAD@{1}..HEAD 2>/dev/null | grep -q "display/main.py" && sudo systemctl restart mbcloud-display.service 2>/dev/null || true
EOF
    chmod +x "$REPO_PATH/scripts/update-mbcloud.sh"
    crontab -l 2>/dev/null | grep -q "update-mbcloud.sh" || (crontab -l 2>/dev/null; echo "0 4 * * * $REPO_PATH/scripts/update-mbcloud.sh") | crontab - 2>/dev/null
    log_ok "Авто-обновление настроено (ежедневно в 04:00)"
}

#===============================================================================
# 🔔, 📊, 🔐, 💾 (опциональные, по умолчанию пропускать)
#===============================================================================

setup_telegram() { [[ "$SKIP_TELEGRAM" = "true" ]] && return 0; log "🔔 Telegram: пропущено (по умолчанию)"; }
setup_monitoring() { [[ "$SKIP_MONITORING" = "true" ]] && return 0; log "📊 Monitoring: пропущено (по умолчанию)"; }
setup_external_access() { [[ "$SKIP_PROXY" = "true" ]] && return 0; log "🔐 Proxy: пропущено (по умолчанию)"; }
setup_backups() { [[ "$SKIP_BACKUP" = "true" ]] && return 0; log "💾 Backups: пропущено (по умолчанию)"; }

#===============================================================================
# 🎛️ ПАРСИНГ АРГУМЕНТОВ
#===============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --minimal) MODE="minimal"; INSTALL_IMMICH=false; INSTALL_MERGERFS=false; INSTALL_AUTOUPDATE=false; shift ;;
            --recommended) MODE="recommended"; INSTALL_IMMICH=true; INSTALL_MERGERFS=true; INSTALL_AUTOUPDATE=true; shift ;;
            --full) MODE="full"; INSTALL_IMMICH=true; INSTALL_MERGERFS=true; INSTALL_AUTOUPDATE=true; SKIP_TELEGRAM=false; SKIP_MONITORING=false; SKIP_PROXY=false; SKIP_BACKUP=false; shift ;;
            --all) MODE="recommended"; shift ;;  # --all = recommended
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
                1) install_immich ;; 2) setup_mergerfs ;; 3) setup_telegram ;; 4) setup_auto_update ;;
                5) setup_monitoring ;; 6) setup_external_access ;; 7) setup_backups ;;
                8) MODE="recommended"; install_immich; setup_mergerfs; setup_auto_update ;;
                *) log_ok "Завершено" ;;
            esac ;;
        minimal) log "Минимальный режим — ничего не устанавливаем" ;;
        recommended|full)
            install_immich
            setup_mergerfs
            setup_auto_update
            [[ "$MODE" = "full" ]] && { setup_telegram; setup_monitoring; setup_external_access; setup_backups; } ;;
        custom)
            [[ "$INSTALL_IMMICH" = "true" ]] && install_immich
            [[ "$INSTALL_MERGERFS" = "true" ]] && setup_mergerfs
            [[ "$INSTALL_AUTOUPDATE" = "true" ]] && setup_auto_update
            [[ "$SKIP_TELEGRAM" = "false" ]] && setup_telegram
            [[ "$SKIP_MONITORING" = "false" ]] && setup_monitoring
            [[ "$SKIP_PROXY" = "false" ]] && setup_external_access
            [[ "$SKIP_BACKUP" = "false" ]] && setup_backups ;;
    esac
    
    echo ""
    log_ok "Установка дополнений завершена!"
    log "Полезные команды:"
    echo -e "  • Immich: ${BLUE}immich up -d${NC}"
    echo -e "  • Grafana: ${BLUE}http://$(hostname -I | awk '{print $1}'):3000${NC} (если установлен)"
    echo -e "  • Proxy: ${BLUE}http://$(hostname -I | awk '{print $1}'):81${NC} (если установлен)"
    echo ""
}

main "$@"
