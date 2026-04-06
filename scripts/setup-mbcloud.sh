#!/bin/bash
#===============================================================================
# mbcloud NAS - Полный скрипт установки и настройки
# Использование: curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash
#===============================================================================

set -e  # Выход при ошибке

# 🎨 Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ⚙️ Конфигурация
REPO_URL="https://github.com/mibitok/mbcloud-system.git"
REPO_BRANCH="main"
REPO_PATH="/home/${SUDO_USER:-mibitok}/mbcloud-system"
MAIN_PY_URL="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/display/main.py"
FONT_URL="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/display/fonts/baveuse_0.ttf"
WAVESHARE_DEMO_URL="https://files.waveshare.com/wiki/CM4-NAS-Double-Deck/CM4-NAS-Double-Deck_Demo.zip"
CONFIG_FILE="/boot/firmware/config.txt"
SERVICE_FILE="/etc/systemd/system/mbcloud-display.service"
DATA_MOUNT="/DATA"
USER="${SUDO_USER:-$(whoami)}"

# 📢 Функции вывода
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }
header() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  mbcloud NAS Setup v2.0            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
    echo "  Время: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Пользователь: $USER $([ $EUID -eq 0 ] && echo '(root)' || echo '')"
    echo ""
}

#===============================================================================
# 🔧 ФУНКЦИИ УСТАНОВКИ
#===============================================================================

check_prerequisites() {
    header "Проверка системы"
    
    if [[ $EUID -ne 0 ]]; then
        log_err "Запустите с: curl ... | sudo bash"
        exit 1
    fi
    
    if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
        log_warn "Не обнаружен Raspberry Pi. Продолжение на свой страх и риск."
        read -p "Продолжить? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    
    log_ok "Система: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
}

update_system() {
    header "Обновление системы"
    log "Обновляем пакеты..."
    apt update -qq && apt upgrade -y -qq
    log_ok "Система обновлена"
}

install_packages() {
    header "Установка зависимостей"
    
    log "Устанавливаем базовые пакеты..."
    apt install -y -qq \
        git curl wget unzip htop tmux \
        python3-pip python3-venv \
        mergerfs smartmontools \
        samba i2c-tools read-edid \
        fonts-dejavu-core \
        libatlas-base-dev libopenjp2-7 libtiff5 \
        2>/dev/null || log_warn "Некоторые пакеты могли не установиться"
    
    log "Устанавливаем Python-зависимости..."
    pip3 install -q --break-system-packages \
        psutil>=5.9.0 \
        gpiozero>=2.0 \
        Pillow>=9.0.0 \
        2>/dev/null || log_warn "Некоторые Python-пакеты могли не установиться"
    
    log_ok "Зависимости установлены"
}

configure_boot() {
    header "Настройка /boot/firmware/config.txt"
    
    [ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M)" 2>/dev/null || true
    
    # Добавляем настройки, если их нет
    grep -q "^dtparam=spi=on" "$CONFIG_FILE" || echo "dtparam=spi=on" >> "$CONFIG_FILE"
    grep -q "^dtparam=i2c_arm=on" "$CONFIG_FILE" || echo "dtparam=i2c_arm=on" >> "$CONFIG_FILE"
    grep -q "dtoverlay=i2c-rtc,pcf85063a" "$CONFIG_FILE" || {
        echo "" >> "$CONFIG_FILE"
        echo "# RTC PCF85063a для CM4-NAS-Double-Deck" >> "$CONFIG_FILE"
        echo "dtoverlay=i2c-rtc,pcf85063a" >> "$CONFIG_FILE"
    }
    
    # Отключаем аудио (опционально)
    grep -q "^dtparam=audio=off" "$CONFIG_FILE" || {
        echo "# Audio disabled for mbcloud NAS" >> "$CONFIG_FILE"
        echo "dtparam=audio=off" >> "$CONFIG_FILE"
    }
    
    log_ok "Конфигурация обновлена (требуется перезагрузка)"
}

download_waveshare_demo() {
    header "Скачивание демо-кода Waveshare"
    
    cd /home/$USER
    if [ ! -d "CM4-NAS-Double-Deck_Demo" ]; then
        log "Скачиваем демо-код..."
        wget -q -O demo.zip "$WAVESHARE_DEMO_URL"
        unzip -q demo.zip
        rm -f demo.zip
        log_ok "Демо-код скачан"
    else
        log_ok "Демо-код уже присутствует"
    fi
}

clone_repository() {
    header "Клонирование репозитория"
    
    if [ -d "$REPO_PATH/.git" ]; then
        log "Обновляем репозиторий..."
        cd "$REPO_PATH" && git pull -q
    else
        log "Клонируем репозиторий..."
        git clone -b "$REPO_BRANCH" "$REPO_URL" "$REPO_PATH" 2>/dev/null || {
            # Fallback: создаём структуру вручную
            mkdir -p "$REPO_PATH"/{display/fonts,scripts,systemd,docker,config,docs}
        }
    fi
    
    chmod +x "$REPO_PATH/scripts/"*.sh 2>/dev/null || true
    log_ok "Репозиторий готов"
}

download_main_py() {
    header "Скачивание main.py с GitHub"
    
    mkdir -p "$REPO_PATH/display"
    
    log "Скачиваем main.py..."
    if curl -sSL -o "$REPO_PATH/display/main.py" "$MAIN_PY_URL"; then
        if python3 -m py_compile "$REPO_PATH/display/main.py" 2>/dev/null; then
            log_ok "main.py скачан и проверен"
        else
            log_err "Ошибка синтаксиса в скачанном main.py!"
            return 1
        fi
    else
        log_err "Не удалось скачать main.py"
        return 1
    fi
}

setup_fonts() {
    header "Настройка шрифтов"
    
    mkdir -p "$REPO_PATH/display/fonts"
    
    if [ ! -s "$REPO_PATH/display/fonts/baveuse_0.ttf" ]; then
        log "Скачиваем шрифт Baveuse..."
        curl -sSL -o "$REPO_PATH/display/fonts/baveuse_0.ttf" "$FONT_URL" 2>/dev/null || \
        wget -q -O "$REPO_PATH/display/fonts/baveuse_0.ttf" "${FONT_URL/.ttf/.zip}" 2>/dev/null || \
        log_warn "Не удалось скачать шрифт автоматически"
    fi
    
    if [ -s "$REPO_PATH/display/fonts/baveuse_0.ttf" ]; then
        log_ok "Шрифт установлен: $(stat -c%s "$REPO_PATH/display/fonts/baveuse_0.ttf") байт"
    else
        log_warn "Шрифт не установлен — дисплей будет использовать шрифт по умолчанию"
    fi
}

setup_lcdconfig() {
    header "Исправление lcdconfig.py (конфликт GPIO)"
    
    local lcdconfig="/home/$USER/CM4-NAS-Double-Deck_Demo/RaspberryPi/lib/lcdconfig.py"
    
    if [ -f "$lcdconfig" ]; then
        # Закомментируем строки с FAN_PIN чтобы не было конфликта с gpiozero
        if grep -q "self.FAN_PIN = self.gpio_pwm" "$lcdconfig" 2>/dev/null; then
            log "Исправляем конфликт GPIO 19 в lcdconfig.py..."
            sed -i 's/^        self\.FAN_PIN = self\.gpio_pwm/        # self.FAN_PIN = self.gpio_pwm/' "$lcdconfig"
            sed -i 's/^        self\.FAN_PIN\.value = 0/        # self.FAN_PIN.value = 0/' "$lcdconfig"
            sed -i 's/^        self\.FAN_PIN\.close()/        # self.FAN_PIN.close()/' "$lcdconfig"
            log_ok "lcdconfig.py исправлен"
        fi
        
        # Очистим кэш Python
        rm -rf "$(dirname "$lcdconfig")/__pycache__" 2>/dev/null || true
    fi
}

setup_systemd_service() {
    header "Настройка systemd сервиса"
    
    # Создаём service файл
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
    
    # Применяем изменения
    systemctl daemon-reload
    systemctl enable mbcloud-display.service 2>/dev/null || true
    
    log_ok "Сервис настроен и включён в автозагрузку"
}

setup_storage() {
    header "Настройка хранилища (MergerFS)"
    
    # Создаём точки монтирования
    mkdir -p /mnt/disk1 /mnt/disk2 "$DATA_MOUNT"
    
    # Проверяем, настроен ли fstab
    if ! grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        log_warn "MergerFS не настроен в /etc/fstab"
        log "Для настройки выполните вручную:"
        echo "  echo '/mnt/disk1:/mnt/disk2  $DATA_MOUNT  fuse.mergerfs  defaults,allow_other,use_ino,category.create=epff  0  0' | sudo tee -a /etc/fstab"
    else
        log_ok "MergerFS уже настроен"
    fi
    
    # Создаём папки для приложений
    for dir in photos import immich-postgres immich-redis backups; do
        mkdir -p "$DATA_MOUNT/$dir"
    done
    chown -R "$USER:$USER" "$DATA_MOUNT" 2>/dev/null || true
    
    log_ok "Хранилище настроено"
}

setup_samba() {
    header "Настройка Samba (сетевой доступ)"
    
    if ! grep -q "^\[mbcloud\]" /etc/samba/smb.conf 2>/dev/null; then
        cat >> /etc/samba/smb.conf << EOF

[mbcloud]
   path = $DATA_MOUNT
   browseable = yes
   read only = no
   guest ok = no
   create mask = 0644
   directory mask = 0755
   force user = $USER
EOF
        log_ok "Samba share [mbcloud] добавлен"
    else
        log_ok "Samba share уже настроен"
    fi
}

finalize() {
    header "Завершение установки"
    
    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  mbcloud NAS ГОТОВ К ИСПОЛЬЗОВАНИЮ!  ${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${GREEN}Следующие шаги:${NC}"
    echo "  1. Перезагрузите систему:  ${YELLOW}sudo reboot${NC}"
    echo "  2. После перезагрузки:"
    echo "     • Дисплей запустится автоматически"
    echo "     • Вентилятор включится при температуре > 60°C"
    echo "     • Immich: ${YELLOW}cd ~/mbcloud-system/docker && docker compose up -d${NC}"
    echo "  3. Настройте пароль Samba: ${YELLOW}sudo smbpasswd -a $USER${NC}"
    echo "  4. Подключите iPhone: ${YELLOW}http://$(hostname -I | awk '{print $1}'):2283${NC}"
    echo ""
    
    echo -e "${YELLOW}Полезные команды:${NC}"
    echo "  • Статус дисплея:  ${BLUE}sudo systemctl status mbcloud-display.service${NC}"
    echo "  • Логи дисплея:    ${BLUE}journalctl -u mbcloud-display.service -f${NC}"
    echo "  • Диагностика:     ${BLUE}~/mbcloud-system/scripts/mbcloud-diagnose.sh${NC}"
    echo "  • Температура:     ${BLUE}vcgencmd measure_temp${NC}"
    echo "  • Место на диске:  ${BLUE}df -h /DATA${NC}"
    echo ""
    
    # Предложение перезагрузки
    read -p "Перезагрузить систему сейчас? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Перезагрузка..."
        reboot
    else
        log_warn "Не забудьте перезагрузить: ${YELLOW}sudo reboot${NC}"
    fi
}

#===============================================================================
# 🚀 ГЛАВНАЯ ФУНКЦИЯ
#===============================================================================
main() {
    header "mbcloud NAS Auto-Setup"
    
    check_prerequisites
    update_system
    install_packages
    configure_boot
    download_waveshare_demo
    clone_repository
    download_main_py          # 🔥 Скачивает main.py с GitHub!
    setup_fonts
    setup_lcdconfig           # 🔥 Исправляет конфликт GPIO
    setup_systemd_service
    setup_storage
    setup_samba
    finalize
}

main "$@"
