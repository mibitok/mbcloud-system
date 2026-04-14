#!/bin/bash
#===============================================================================
# mbcloud NAS - Полная установка (v3.0 - Clean Install Ready)
# Использование: curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash
#===============================================================================

# 🎨 Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ⚙️ Переменные
REPO_BRANCH="main"
USER="${SUDO_USER:-$(whoami)}"
HOME_DIR="/home/$USER"
REPO_PATH="$HOME_DIR/mbcloud-system"
CONFIG_FILE="/boot/firmware/config.txt"
SERVICE_FILE="/etc/systemd/system/mbcloud-display.service"
DATA_MOUNT="/DATA"
IMMICH_PORT="2283"

# 📢 Логирование
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_err() { echo -e "${RED}[✗]${NC} $1"; }

header() {
    echo ""; echo -e "${GREEN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  mbcloud NAS Setup v3.0            ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════╝${NC}"
    echo "  $(date '+%Y-%m-%d %H:%M:%S') | User: $USER"
    echo ""
}

#===============================================================================
# 🔧 БАЗОВЫЕ ФУНКЦИИ
#===============================================================================

check_root() {
    [[ $EUID -ne 0 ]] && { log_err "Запустите с sudo или под root"; exit 1; }
}

create_dirs() {
    log "Создаём структуру папок..."
    mkdir -p "$REPO_PATH"/{display/fonts,scripts,systemd,docker,config,docs}
    mkdir -p /mnt/disk1 /mnt/disk2 "$DATA_MOUNT"
    for dir in photos import immich-postgres immich-redis backups; do mkdir -p "$DATA_MOUNT/$dir"; done
    chown -R "$USER:$USER" "$REPO_PATH" "$DATA_MOUNT" 2>/dev/null || true
    log_ok "Структура папок создана"
}

update_system() {
    header "Обновление системы"
    log "Обновляем пакеты..."
    apt update -qq && apt upgrade -y -qq
    log_ok "Система обновлена"
}

install_base_deps() {
    header "Установка базовых зависимостей"
    log "Устанавливаем системные пакеты..."
    apt install -y -qq git curl wget unzip htop tmux python3-pip python3-venv mergerfs smartmontools samba i2c-tools read-edid fonts-dejavu-core libatlas-base-dev libopenjp2-7 libtiff5 2>/dev/null || log_warn "Некоторые пакеты могли не установиться"
    log_ok "Зависимости установлены"
}

configure_boot() {
    header "Настройка /boot/firmware/config.txt"
    [ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M)" 2>/dev/null || true

    # Умное добавление настроек без дублей
    local settings=("dtparam=spi=on" "dtparam=i2c_arm=on" "dtoverlay=i2c-rtc,pcf85063a" "dtparam=audio=off")
    for s in "${settings[@]}"; do
        grep -q "^${s//=/=}" "$CONFIG_FILE" 2>/dev/null || echo "$s" >> "$CONFIG_FILE"
    done
    sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$CONFIG_FILE" 2>/dev/null
    log_ok "Конфигурация обновлена (требуется reboot)"
}

download_display_files() {
    header "Скачивание файлов дисплея"
    local main_url="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/display/main.py"
    local font_url="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/display/fonts/baveuse_0.ttf"

    log "Скачиваем main.py..."
    curl -sSL -o "$REPO_PATH/display/main.py" "$main_url" && python3 -m py_compile "$REPO_PATH/display/main.py" 2>/dev/null && log_ok "main.py проверен" || log_err "Ошибка main.py"

    log "Скачиваем шрифт..."
    mkdir -p "$REPO_PATH/display/fonts"
    curl -sSL -o "$REPO_PATH/display/fonts/baveuse_0.ttf" "$font_url"
    [ -s "$REPO_PATH/display/fonts/baveuse_0.ttf" ] && log_ok "Шрифт установлен" || log_warn "Шрифт не скачался"
    chown -R "$USER:$USER" "$REPO_PATH/display" 2>/dev/null || true
}

setup_systemd() {
    header "Настройка сервиса дисплея"
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=mbcloud NAS LCD Display Service
After=network.target multi-user.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$REPO_PATH/display
ExecStart=/usr/bin/python3 $REPO_PATH/display/main.py
Restart=on-failure
RestartSec=5s
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mbcloud-display.service 2>/dev/null || true
    log_ok "Сервис настроен"
}

install_python_deps() {
    header "Установка Python-зависимостей"
    apt install -y -qq python3-psutil python3-gpiozero python3-pil python3-numpy 2>/dev/null || \
    pip3 install -q --break-system-packages psutil gpiozero Pillow numpy 2>/dev/null || log_warn "Python пакеты не установлены"
    log_ok "Python зависимости готовы"
}

setup_waveshare_demo() {
    header "Исправление Waveshare Demo (конфликт GPIO 19)"
    cd "$HOME_DIR" || exit 1
    if [ ! -d "CM4-NAS-Double-Deck_Demo" ]; then
        log "Скачиваем демо-код Waveshare..."
        wget -q -O demo.zip "https://files.waveshare.com/wiki/CM4-NAS-Double-Deck/CM4-NAS-Double-Deck_Demo.zip"
        unzip -q demo.zip && rm -f demo.zip
    fi
    local lcd="$HOME_DIR/CM4-NAS-Double-Deck_Demo/RaspberryPi/lib/lcdconfig.py"
    if [ -f "$lcd" ]; then
        sed -i 's/self\.FAN_PIN = self\.gpio_pwm/# self.FAN_PIN = self.gpio_pwm/g' "$lcd"
        sed -i 's/self\.FAN_PIN\.value = 0/# self.FAN_PIN.value = 0/g' "$lcd"
        rm -rf "$(dirname "$lcd")/__pycache__" 2>/dev/null
        log_ok "lcdconfig.py исправлен"
    fi
}

#===============================================================================
# 🐳 DOCKER & IMMICH (Опционально)
#===============================================================================

install_docker_immich() {
    header "Установка Docker + Immich"
    read -p "Установить Docker и Immich (рекомендуется)? (y/N): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && return 0

    if ! command -v docker &>/dev/null; then
        log "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh && usermod -aG docker "$USER" && log_ok "Docker установлен" || log_err "Ошибка Docker"
        rm -f /tmp/get-docker.sh
    else log_ok "Docker уже установлен"; fi

    log "Настраиваем Immich..."
    local compose="$REPO_PATH/docker/docker-compose.yml"
    local env="$REPO_PATH/docker/.env"
    mkdir -p "$REPO_PATH/docker"

    if [ ! -f "$compose" ]; then
        cat > "$compose" << 'EOF'
services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:release
    volumes:
      - ${UPLOAD_LOCATION}:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    env_file: .env
    ports: ["2283:2283"]
    depends_on: [redis, database]
    restart: always
  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:release
    volumes: [./model-cache:/cache]
    env_file: .env
    restart: always
    depends_on: [database]
  redis:
    container_name: immich_redis
    image: redis:6.2-alpine
    restart: always
  database:
    container_name: immich_postgres
    image: tensorchord/pgvecto-rs:pg14-v0.2.0
    env_file: .env
    volumes: [/DATA/immich-postgres:/var/lib/postgresql/data]
    restart: always
EOF
    fi

    if [ ! -f "$env" ]; then
        local pass=$(openssl rand -hex 16)
        cat > "$env" << EOF
DB_PASSWORD=$pass
DB_USERNAME=immich
DB_DATABASE_NAME=immich
UPLOAD_LOCATION=/DATA/immich-upload
TZ=Europe/Moscow
EOF
    fi

    log "Запускаем Immich (может занять 5-10 мин)..."
    cd "$REPO_PATH/docker" && docker compose up -d && log_ok "Immich запущен: http://$(hostname -I | awk '{print $1}'):$IMMICH_PORT" || log_err "Ошибка запуска Immich"
}

#===============================================================================
# 🩺 ВСТРОЕННАЯ ДИАГНОСТИКА (вместо внешнего файла)
#===============================================================================

run_health_check() {
    header "Проверка установки"
    local pass=0; fail=0

    check_item() { if $1; then echo -e "${GREEN}[✓]${NC} $2"; ((pass++)); else echo -e "${RED}[✗]${NC} $2"; ((fail++)); fi; }

    systemctl is-active mbcloud-display.service &>/dev/null && check_item true "Сервис дисплея активен" || check_item false "Сервис дисплея"
    systemctl is-active smbd &>/dev/null && check_item true "Samba активна" || check_item false "Samba"
    command -v docker &>/dev/null && docker compose -f "$REPO_PATH/docker/docker-compose.yml" ps &>/dev/null && check_item true "Immich запущен" || check_item false "Immich"
    [ -f "$REPO_PATH/display/main.py" ] && check_item true "main.py существует" || check_item false "main.py"
    [ -f "$REPO_PATH/display/fonts/baveuse_0.ttf" ] && check_item true "Шрифт установлен" || check_item false "Шрифт"
    vcgencmd measure_temp &>/dev/null && check_item true "Температура: $(vcgencmd measure_temp)" || check_item false "Температура"

    echo -e "\n${BOLD}Итого: ${GREEN}$pass OK${NC} | ${RED}$fail FAIL${NC}${NC}"
    [[ $fail -eq 0 ]] && echo -e "${GREEN}${BOLD}🎉 ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ!${NC}" || echo -e "${YELLOW}⚠️  Есть предупреждения. Проверьте логи.${NC}"
    echo ""
}

#===============================================================================
# 🚀 ГЛАВНАЯ ФУНКЦИЯ
#===============================================================================

main() {
    check_root
    create_dirs
    update_system
    install_base_deps
    install_python_deps
    configure_boot
    setup_waveshare_demo
    download_display_files
    setup_systemd
    install_docker_immich
    
    header "Завершение"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  mbcloud NAS УСТАНОВЛЕН!  ${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo "Следующие шаги:"
    echo "  1. Перезагрузите: ${YELLOW}sudo reboot${NC}"
    echo "  2. Immich: ${YELLOW}cd ~/mbcloud-system/docker && docker compose up -d${NC}"
    echo "  3. Samba пароль: ${YELLOW}sudo smbpasswd -a $USER${NC}"
    echo ""
    run_health_check
    
    read -p "Перезагрузить сейчас? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && { log "Перезагрузка..."; reboot; } || log_warn "Не забудьте: ${YELLOW}sudo reboot${NC}"
}

main "$@"
