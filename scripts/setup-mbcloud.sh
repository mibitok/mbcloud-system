#!/bin/bash
#===============================================================================
# mbcloud NAS - Полный скрипт установки с проверкой и авто-восстановлением (v2.3)
# Использование:
#   • Полная установка:  curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash
#   • Только проверка:   curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash -s -- --check
#===============================================================================

set -e  # Выход при ошибке

# 🎨 Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ⚙️ Конфигурация
REPO_URL="https://github.com/mibitok/mbcloud-system.git"
REPO_BRANCH="main"
# 🔧 Надёжное определение пути к репозиторию
if [ -n "$SUDO_USER" ] && [ -d "/home/$SUDO_USER/mbcloud-system" ]; then
    REPO_PATH="/home/$SUDO_USER/mbcloud-system"
elif [ -d "$HOME/mbcloud-system" ]; then
    REPO_PATH="$HOME/mbcloud-system"
elif [ -d "/root/mbcloud-system" ]; then
    REPO_PATH="/root/mbcloud-system"
else
    REPO_PATH="/home/${SUDO_USER:-mibitok}/mbcloud-system"
fi
# 🔗 Raw-ссылки для скачивания (НЕ blob!)
MAIN_PY_URL="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/display/main.py"
FONT_URL="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/display/fonts/baveuse_0.ttf"
WAVESHARE_URL="https://files.waveshare.com/wiki/CM4-NAS-Double-Deck/CM4-NAS-Double-Deck_Demo.zip"
CONFIG_FILE="/boot/firmware/config.txt"
SERVICE_FILE="/etc/systemd/system/mbcloud-display.service"
DATA_MOUNT="/DATA"
USER="${SUDO_USER:-$(whoami)}"

# 📊 Счётчики проверок
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0

# 📢 Функции вывода
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; ((CHECKS_PASSED++)); }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; ((CHECKS_SKIPPED++)); }
log_err() { echo -e "${RED}[✗]${NC} $1"; ((CHECKS_FAILED++)); }
log_check() { echo -e "${CYAN}[→]${NC} $1"; }

header() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  mbcloud NAS Setup v2.3            ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════╝${NC}"
    echo "  $(date '+%Y-%m-%d %H:%M:%S') | User: $USER"
    echo ""
}

#===============================================================================
# ✅ ФУНКЦИИ ПРОВЕРКИ КОМПОНЕНТОВ (с авто-восстановлением)
#===============================================================================

check_python_syntax() {
    log_check "Проверка синтаксиса main.py..."
    local main_py="$REPO_PATH/display/main.py"
    
    # 🔧 Если файл не найден — пробуем скачать автоматически!
    if [ ! -f "$main_py" ]; then
        log_warn "main.py: файл не найден, пробуем скачать..."
        sudo mkdir -p "$(dirname "$main_py")"
        
        if curl -sSL -o "$main_py" "$MAIN_PY_URL" 2>/dev/null; then
            if sudo python3 -m py_compile "$main_py" 2>/dev/null; then
                log_ok "main.py: скачан и проверен"
                sudo chown -R "$USER:$USER" "$(dirname "$main_py")" 2>/dev/null || true
                return 0
            else
                log_err "main.py: скачан, но ошибка синтаксиса"
                return 1
            fi
        else
            log_err "main.py: не удалось скачать"
            log "Попробуйте вручную: curl -sSL $MAIN_PY_URL -o $main_py"
            return 1
        fi
    fi
    
    # Файл есть — проверяем синтаксис
    if sudo python3 -m py_compile "$main_py" 2>/dev/null; then
        log_ok "main.py: синтаксис верный"
        return 0
    else
        log_err "main.py: ошибка синтаксиса"
        return 1
    fi
}

check_font_file() {
    log_check "Проверка шрифта Baveuse..."
    local font="$REPO_PATH/display/fonts/baveuse_0.ttf"
    
    # 🔧 Если шрифт не найден — пробуем скачать
    if [ ! -f "$font" ]; then
        log_warn "Шрифт: не найден, пробуем скачать..."
        sudo mkdir -p "$(dirname "$font")"
        
        if curl -sSL -o "$font" "$FONT_URL" 2>/dev/null; then
            local size=$(stat -c%s "$font" 2>/dev/null || echo 0)
            if [ "$size" -gt 50000 ]; then
                if python3 -c "from PIL import ImageFont; ImageFont.truetype('$font', 24)" 2>/dev/null; then
                    log_ok "Шрифт: скачан и валиден ($size байт)"
                    sudo chown -R "$USER:$USER" "$(dirname "$font")" 2>/dev/null || true
                    return 0
                else
                    log_warn "Шрифт: скачан, но не загружается через PIL"
                    return 1
                fi
            else
                log_err "Шрифт: скачан, но слишком мал ($size байт)"
                return 1
            fi
        else
            log_err "Шрифт: не удалось скачать"
            log "Попробуйте вручную: curl -sSL $FONT_URL -o $font"
            return 1
        fi
    fi
    
    # Файл есть — проверяем
    local size=$(stat -c%s "$font" 2>/dev/null || echo 0)
    if [ "$size" -gt 50000 ]; then
        log_ok "Шрифт: $size байт (валидный)"
        if python3 -c "from PIL import ImageFont; ImageFont.truetype('$font', 24)" 2>/dev/null; then
            log_ok "Шрифт: загружается через PIL"
            return 0
        else
            log_warn "Шрифт: не загружается через PIL (возможно, повреждён)"
            return 1
        fi
    else
        log_err "Шрифт: слишком мал ($size байт)"
        return 1
    fi
}

check_systemd_service() {
    log_check "Проверка systemd сервиса..."
    
    if [ -f "$SERVICE_FILE" ]; then
        log_ok "Сервис: файл $SERVICE_FILE существует"
        
        if sudo systemctl is-enabled mbcloud-display.service &>/dev/null; then
            log_ok "Сервис: включён в автозагрузку"
        else
            log_warn "Сервис: не включён в автозагрузку"
        fi
        
        if sudo systemctl is-active mbcloud-display.service &>/dev/null; then
            log_ok "Сервис: активен (running)"
            return 0
        else
            log_warn "Сервис: не активен (возможно, требуется перезагрузка)"
            return 0
        fi
    else
        log_err "Сервис: файл не найден"
        return 1
    fi
}

check_gpio_interfaces() {
    log_check "Проверка интерфейсов GPIO..."
    
    if [ -c /dev/spidev0.0 ]; then
        log_ok "SPI: /dev/spidev0.0 доступен"
    else
        log_warn "SPI: /dev/spidev0.0 не найден (проверьте dtparam=spi=on)"
    fi
    
    if [ -c /dev/i2c-1 ]; then
        log_ok "I2C: /dev/i2c-1 доступен"
        if command -v i2cdetect &>/dev/null; then
            if sudo i2cdetect -y 1 2>/dev/null | grep -qE "51|68"; then
                log_ok "RTC: обнаружен на шине I2C"
            else
                log_warn "RTC: не обнаружен (адрес 0x51 или 0x68)"
            fi
        fi
    else
        log_warn "I2C: /dev/i2c-1 не найден (проверьте dtparam=i2c_arm=on)"
    fi
}

check_python_packages() {
    log_check "Проверка Python-зависимостей..."
    
    local packages=("psutil" "gpiozero" "PIL")
    local missing=()
    
    for pkg in "${packages[@]}"; do
        if python3 -c "import $pkg" 2>/dev/null; then
            log_ok "Python: $pkg установлен"
        else
            missing+=("$pkg")
            log_warn "Python: $pkg не найден"
        fi
    done
    
    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    else
        log_warn "Отсутствуют пакеты: ${missing[*]}"
        log "Установите: sudo pip3 install --break-system-packages ${missing[*]}"
        return 1
    fi
}

check_waveshare_demo() {
    log_check "Проверка демо-кода Waveshare..."
    
    local lcdconfig="/home/$USER/CM4-NAS-Double-Deck_Demo/RaspberryPi/lib/lcdconfig.py"
    
    if [ -f "$lcdconfig" ]; then
        log_ok "Демо-код: lcdconfig.py найден"
        
        if grep -q "^#.*self\.FAN_PIN = self\.gpio_pwm" "$lcdconfig" 2>/dev/null; then
            log_ok "Демо-код: конфликт GPIO 19 исправлен"
            return 0
        else
            log_warn "Демо-код: FAN_PIN может конфликтовать (проверьте lcdconfig.py)"
            return 1
        fi
    else
        log_warn "Демо-код: lcdconfig.py не найден"
        return 0
    fi
}

check_storage() {
    log_check "Проверка хранилища..."
    
    for dir in /mnt/disk1 /mnt/disk2 "$DATA_MOUNT"; do
        if [ -d "$dir" ]; then
            log_ok "Хранилище: $dir существует"
        else
            log_warn "Хранилище: $dir не существует"
        fi
    done
    
    if [ -d "$DATA_MOUNT" ]; then
        local owner=$(stat -c%U "$DATA_MOUNT" 2>/dev/null)
        if [ "$owner" = "$USER" ]; then
            log_ok "Хранилище: права на $DATA_MOUNT корректны"
        else
            log_warn "Хранилище: владелец $DATA_MOUNT = $owner (ожидалось $USER)"
        fi
    fi
    
    if sudo grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        log_ok "MergerFS: настроен в /etc/fstab"
    else
        log_warn "MergerFS: не настроен в /etc/fstab (опционально)"
    fi
    
    return 0
}

check_samba() {
    log_check "Проверка Samba..."
    
    if command -v smbpasswd &>/dev/null; then
        log_ok "Samba: установлен"
        
        if sudo grep -q "^\[mbcloud\]" /etc/samba/smb.conf 2>/dev/null; then
            log_ok "Samba: share [mbcloud] настроен"
        else
            log_warn "Samba: share [mbcloud] не настроен"
        fi
        
        if sudo systemctl is-active smbd &>/dev/null; then
            log_ok "Samba: сервис активен"
            return 0
        else
            log_warn "Samba: сервис не активен"
            return 0
        fi
    else
        log_warn "Samba: не установлен (опционально)"
        return 0
    fi
}

check_docker() {
    log_check "Проверка Docker..."
    
    if command -v docker &>/dev/null && (command -v docker-compose &>/dev/null || docker compose version &>/dev/null); then
        log_ok "Docker: установлен"
        
        local compose_file="$REPO_PATH/docker/docker-compose.yml"
        if [ -f "$compose_file" ]; then
            log_ok "Docker: docker-compose.yml найден"
        else
            log_warn "Docker: docker-compose.yml не найден"
        fi
        return 0
    else
        log_warn "Docker: не установлен (опционально для Immich)"
        return 0
    fi
}

check_network() {
    log_check "Проверка сети..."
    
    local ip=$(hostname -I | awk '{print $1}')
    if [ -n "$ip" ]; then
        log_ok "Сеть: IP адрес $ip"
        
        if sudo ss -tlnp 2>/dev/null | grep -q ":2283 "; then
            log_ok "Сеть: порт 2283 (Immich) слушается"
        else
            log_warn "Сеть: порт 2283 не слушается (Immich может быть не запущен)"
        fi
        return 0
    else
        log_warn "Сеть: не удалось определить IP адрес"
        return 1
    fi
}

print_verification_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  ПРОВЕРКА УСТАНОВКИ${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${BOLD}Результаты:${NC}"
    echo -e "  ${GREEN}✓ Прошло:${NC}     $CHECKS_PASSED"
    echo -e "  ${YELLOW}⚠ Предупреждения:${NC} $CHECKS_SKIPPED"
    echo -e "  ${RED}✗ Ошибки:${NC}      $CHECKS_FAILED"
    echo ""
    
    if [ $CHECKS_FAILED -eq 0 ]; then
        echo -e "${GREEN}${BOLD}🎉 ВСЕ КРИТИЧЕСКИЕ ПРОВЕРКИ ПРОЙДЕНЫ!${NC}"
        echo "Система готова к использованию."
    else
        echo -e "${RED}${BOLD}⚠ ЕСТЬ ОШИБКИ${NC}"
        echo "Исправьте $CHECKS_FAILED ошибок для полной работоспособности."
    fi
    
    echo ""
    echo -e "${BOLD}Полезные команды:${NC}"
    echo "  • Перезапуск дисплея:  ${BLUE}sudo systemctl restart mbcloud-display.service${NC}"
    echo "  • Логи дисплея:        ${BLUE}journalctl -u mbcloud-display.service -f${NC}"
    echo "  • Запуск Immich:       ${BLUE}cd ~/mbcloud-system/docker && docker compose up -d${NC}"
    echo "  • Пароль Samba:        ${BLUE}sudo smbpasswd -a $USER${NC}"
    echo "  • Перезагрузка:        ${BLUE}sudo reboot${NC}"
    echo ""
}

run_all_checks() {
    header "Проверка установленных компонентов"
    
    check_python_syntax
    check_font_file
    check_systemd_service
    check_gpio_interfaces
    check_python_packages
    check_waveshare_demo
    check_storage
    check_samba
    check_docker
    check_network
    
    print_verification_summary
    
    return $CHECKS_FAILED
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
    sudo apt update -qq && sudo apt upgrade -y -qq
    log_ok "Система обновлена"
}

install_packages() {
    header "Установка зависимостей"
    
    log "Устанавливаем базовые пакеты..."
    sudo apt install -y -qq \
        git curl wget unzip htop tmux \
        python3-pip python3-venv \
        mergerfs smartmontools \
        samba i2c-tools read-edid \
        fonts-dejavu-core \
        libatlas-base-dev libopenjp2-7 libtiff5 \
        2>/dev/null || log_warn "Некоторые пакеты могли не установиться"
    
    log "Устанавливаем Python-зависимости..."
    sudo pip3 install -q --break-system-packages \
        psutil>=5.9.0 \
        gpiozero>=2.0 \
        Pillow>=9.0.0 \
        2>/dev/null || log_warn "Некоторые Python-пакеты могли не установиться"
    
    log_ok "Зависимости установлены"
}

configure_boot() {
    header "Настройка /boot/firmware/config.txt"
    
    [ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"
    sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M)" 2>/dev/null || true
    
    sudo bash -c "grep -q '^dtparam=spi=on' '$CONFIG_FILE' || echo 'dtparam=spi=on' >> '$CONFIG_FILE'"
    sudo bash -c "grep -q '^dtparam=i2c_arm=on' '$CONFIG_FILE' || echo 'dtparam=i2c_arm=on' >> '$CONFIG_FILE'"
    sudo bash -c "grep -q 'dtoverlay=i2c-rtc,pcf85063a' '$CONFIG_FILE' || echo -e '\ndtoverlay=i2c-rtc,pcf85063a' >> '$CONFIG_FILE'"
    sudo bash -c "grep -q '^dtparam=audio=off' '$CONFIG_FILE' || echo 'dtparam=audio=off' >> '$CONFIG_FILE'"
    
    log_ok "Конфигурация обновлена (требуется перезагрузка)"
}

download_waveshare_demo() {
    header "Скачивание демо-кода Waveshare"
    
    cd /home/$USER
    if [ ! -d "CM4-NAS-Double-Deck_Demo" ]; then
        log "Скачиваем демо-код..."
        wget -q -O demo.zip "$WAVESHARE_URL"
        unzip -q demo.zip
        rm -f demo.zip
        log_ok "Демо-код скачан"
    else
        log_ok "Демо-код уже присутствует"
    fi
    
    local lcdconfig="/home/$USER/CM4-NAS-Double-Deck_Demo/RaspberryPi/lib/lcdconfig.py"
    if [ -f "$lcdconfig" ]; then
        log "Исправляем конфликт GPIO 19 в lcdconfig.py..."
        sudo sed -i 's/self\.FAN_PIN = self\.gpio_pwm/# self.FAN_PIN = self.gpio_pwm/g' "$lcdconfig"
        sudo sed -i 's/self\.FAN_PIN\.value = 0/# self.FAN_PIN.value = 0/g' "$lcdconfig"
        sudo sed -i 's/self\.FAN_PIN\.close()/# self.FAN_PIN.close()/g' "$lcdconfig"
        sudo rm -rf "$(dirname "$lcdconfig")/__pycache__" 2>/dev/null || true
        log_ok "lcdconfig.py исправлен"
    fi
}

clone_repository() {
    header "Клонирование репозитория"
    
    if [ -d "$REPO_PATH/.git" ]; then
        log "Обновляем репозиторий..."
        cd "$REPO_PATH" && git pull -q
    else
        log "Клонируем репозиторий..."
        sudo -u "$USER" git clone -b "$REPO_BRANCH" "$REPO_URL" "$REPO_PATH" 2>/dev/null || {
            sudo mkdir -p "$REPO_PATH"/{display/fonts,scripts,systemd,docker,config,docs}
            sudo chown -R "$USER:$USER" "$REPO_PATH"
        }
    fi
    
    sudo chmod +x "$REPO_PATH/scripts/"*.sh 2>/dev/null || true
    log_ok "Репозиторий готов"
}

download_main_py() {
    header "Скачивание main.py с GitHub"
    
    sudo mkdir -p "$REPO_PATH/display"
    
    log "Скачиваем main.py..."
    if curl -sSL -o "$REPO_PATH/display/main.py" "$MAIN_PY_URL"; then
        if sudo python3 -m py_compile "$REPO_PATH/display/main.py" 2>/dev/null; then
            log_ok "main.py скачан и проверен"
        else
            log_err "Ошибка синтаксиса в скачанном main.py!"
            return 1
        fi
    else
        log_err "Не удалось скачать main.py"
        return 1
    fi
    
    sudo chown -R "$USER:$USER" "$REPO_PATH/display" 2>/dev/null || true
}

setup_fonts() {
    header "Настройка шрифтов"
    
    sudo mkdir -p "$REPO_PATH/display/fonts"
    
    if [ ! -s "$REPO_PATH/display/fonts/baveuse_0.ttf" ]; then
        log "Скачиваем шрифт Baveuse..."
        curl -sSL -o "$REPO_PATH/display/fonts/baveuse_0.ttf" "$FONT_URL" 2>/dev/null || \
        log_warn "Не удалось скачать шрифт автоматически"
    fi
    
    if [ -s "$REPO_PATH/display/fonts/baveuse_0.ttf" ]; then
        local size=$(sudo stat -c%s "$REPO_PATH/display/fonts/baveuse_0.ttf" 2>/dev/null || echo 0)
        log_ok "Шрифт установлен: $size байт"
    else
        log_warn "Шрифт не установлен — дисплей будет использовать шрифт по умолчанию"
    fi
    
    sudo chown -R "$USER:$USER" "$REPO_PATH/display/fonts" 2>/dev/null || true
}

setup_systemd_service() {
    header "Настройка systemd сервиса"
    
    sudo tee "$SERVICE_FILE" > /dev/null << EOF
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
    
    sudo systemctl daemon-reload
    sudo systemctl enable mbcloud-display.service 2>/dev/null || true
    
    log_ok "Сервис настроен и включён в автозагрузку"
}

setup_storage() {
    header "Настройка хранилища (MergerFS)"
    
    sudo mkdir -p /mnt/disk1 /mnt/disk2 "$DATA_MOUNT"
    
    if ! sudo grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        log_warn "MergerFS не настроен в /etc/fstab"
        log "Для настройки выполните вручную:"
        echo "  echo '/mnt/disk1:/mnt/disk2  $DATA_MOUNT  fuse.mergerfs  defaults,allow_other,use_ino,category.create=epff  0  0' | sudo tee -a /etc/fstab"
    else
        log_ok "MergerFS уже настроен"
    fi
    
    for dir in photos import immich-postgres immich-redis backups; do
        sudo mkdir -p "$DATA_MOUNT/$dir"
    done
    sudo chown -R "$USER:$USER" "$DATA_MOUNT" 2>/dev/null || true
    
    log_ok "Хранилище настроено"
}

setup_samba() {
    header "Настройка Samba (сетевой доступ)"
    
    if ! command -v smbpasswd &> /dev/null; then
        log "Устанавливаем Samba..."
        sudo apt install -y -qq samba 2>/dev/null || log_warn "Не удалось установить Samba"
    fi
    
    if ! sudo grep -q "^\[mbcloud\]" /etc/samba/smb.conf 2>/dev/null; then
        sudo bash -c "cat >> /etc/samba/smb.conf << EOF

[mbcloud]
   path = $DATA_MOUNT
   browseable = yes
   read only = no
   guest ok = no
   create mask = 0644
   directory mask = 0755
   force user = $USER
EOF
"
        log_ok "Samba share [mbcloud] добавлен"
        sudo systemctl restart smbd 2>/dev/null || true
        sudo systemctl enable smbd 2>/dev/null || true
    else
        log_ok "Samba share уже настроен"
    fi
    
    log "Для доступа к файлам по сети задайте пароль Samba:"
    log "Выполните: sudo smbpasswd -a $USER"
}

finalize() {
    header "✅ Установка завершена!"
    
    # Запускаем проверку компонентов
    run_all_checks
    
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
    echo "  • Логи:            ${BLUE}journalctl -u mbcloud-display.service -f${NC}"
    echo "  • Диагностика:     ${BLUE}~/mbcloud-system/scripts/mbcloud-diagnose.sh${NC}"
    echo "  • Температура:     ${BLUE}vcgencmd measure_temp${NC}"
    echo "  • Место на диске:  ${BLUE}df -h /DATA${NC}"
    echo ""
    
    read -p "Перезагрузить систему сейчас? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Перезагрузка..."
        sudo reboot
    else
        log_warn "Не забудьте перезагрузить: ${YELLOW}sudo reboot${NC}"
    fi
}

#===============================================================================
# 🚀 ГЛАВНАЯ ФУНКЦИЯ
#===============================================================================
main() {
    header "mbcloud NAS Auto-Setup v2.3"
    
    check_prerequisites
    update_system
    install_packages
    configure_boot
    download_waveshare_demo
    clone_repository
    download_main_py
    setup_fonts
    setup_systemd_service
    setup_storage
    setup_samba
    finalize
}

# Обработка аргументов: только проверка
if [[ "${1:-}" == "--check" || "${1:-}" == "-c" ]]; then
    run_all_checks
    exit $?
fi

main "$@"
