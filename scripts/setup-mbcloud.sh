#!/bin/bash
#===============================================================================
# mbcloud NAS - Финальный скрипт установки (v2.8 - config.txt replace + numpy)
# Использование:
#   • Установка:  curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash
#   • Проверка:   curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash -s -- --check
#===============================================================================

# 🎨 Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ⚙️ Конфигурация
REPO_URL="https://github.com/mibitok/mbcloud-system.git"
REPO_BRANCH="main"

if [ -n "$SUDO_USER" ] && [ -d "/home/$SUDO_USER/mbcloud-system" ]; then
    REPO_PATH="/home/$SUDO_USER/mbcloud-system"
elif [ -d "$HOME/mbcloud-system" ]; then
    REPO_PATH="$HOME/mbcloud-system"
elif [ -d "/root/mbcloud-system" ]; then
    REPO_PATH="/root/mbcloud-system"
else
    REPO_PATH="/home/${SUDO_USER:-mibitok}/mbcloud-system"
fi

# 🔗 Raw-ссылки
MAIN_PY_URL="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/display/main.py"
FONT_URL="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/display/fonts/baveuse_0.ttf"
SERVICE_URL="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/systemd/mbcloud-display.service"
CONFIG_CLEAN_URL="https://raw.githubusercontent.com/mibitok/mbcloud-system/${REPO_BRANCH}/config/config.txt.clean"
WAVESHARE_URL="https://files.waveshare.com/wiki/CM4-NAS-Double-Deck/CM4-NAS-Double-Deck_Demo.zip"
CONFIG_FILE="/boot/firmware/config.txt"
SERVICE_FILE="/etc/systemd/system/mbcloud-display.service"
DATA_MOUNT="/DATA"
USER="${SUDO_USER:-$(whoami)}"

CHECKS_PASSED=0; CHECKS_FAILED=0; CHECKS_SKIPPED=0

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; ((CHECKS_PASSED++)) || true; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; ((CHECKS_SKIPPED++)) || true; }
log_err() { echo -e "${RED}[✗]${NC} $1"; ((CHECKS_FAILED++)) || true; }
log_check() { echo -e "${CYAN}[→]${NC} $1"; }

header() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  mbcloud NAS Setup v2.8            ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════╝${NC}"
    echo "  $(date '+%Y-%m-%d %H:%M:%S') | User: $USER"
    echo ""
}

#===============================================================================
# 🔧 УНИВЕРСАЛЬНАЯ ФУНКЦИЯ СКАЧИВАНИЯ
#===============================================================================
download_file() {
    local url="$1"; local dest="$2"; local tmp="/tmp/mbcloud_dl_$$.tmp"; local http_code=""
    if command -v curl &>/dev/null; then
        http_code=$(curl -sSL --connect-timeout 10 --max-time 30 -w "%{http_code}" -o "$tmp" "$url" 2>/dev/null)
        [ "$http_code" = "200" ] && [ -s "$tmp" ] && { mv "$tmp" "$dest" 2>/dev/null && return 0; }
    fi
    if command -v wget &>/dev/null; then
        wget -q --timeout=30 -O "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ] && { mv "$tmp" "$dest" 2>/dev/null && return 0; }
    fi
    if command -v curl &>/dev/null; then
        curl -sSL --connect-timeout 10 --max-time 30 "$url" 2>/dev/null | sudo tee "$tmp" > /dev/null && [ -s "$tmp" ] && { sudo mv "$tmp" "$dest" 2>/dev/null && return 0; }
    fi
    rm -f "$tmp" 2>/dev/null; return 1
}

#===============================================================================
# ✅ ПРОВЕРКИ
#===============================================================================
check_python_syntax() {
    log_check "Проверка синтаксиса main.py..."
    local main_py="$REPO_PATH/display/main.py"
    if [ ! -f "$main_py" ]; then
        log_warn "main.py: файл не найден, пробуем скачать..."
        local tmp_file="/tmp/mbcloud_main_$$.py"
        if download_file "$MAIN_PY_URL" "$tmp_file"; then
            if head -1 "$tmp_file" 2>/dev/null | grep -q "^#!.*python" && python3 -m py_compile "$tmp_file" 2>/dev/null; then
                sudo mkdir -p "$(dirname "$main_py")"; sudo cp "$tmp_file" "$main_py"
                sudo chown "$USER:$USER" "$main_py" 2>/dev/null || true; sudo chmod 644 "$main_py" 2>/dev/null || true
                rm -f "$tmp_file"; log_ok "main.py: скачан и проверен"; return 0
            else log_err "main.py: ошибка в скачанном файле"; fi
        else log_err "main.py: не удалось скачать"; fi
        rm -f "$tmp_file" 2>/dev/null; return 1
    fi
    python3 -m py_compile "$main_py" 2>/dev/null && { log_ok "main.py: синтаксис верный"; return 0; } || { log_err "main.py: ошибка синтаксиса"; return 1; }
}

check_font_file() {
    log_check "Проверка шрифта Baveuse..."
    local font="$REPO_PATH/display/fonts/baveuse_0.ttf"
    if [ ! -f "$font" ]; then
        log_warn "Шрифт: не найден, пробуем скачать..."
        local tmp_file="/tmp/mbcloud_font_$$.ttf"
        if download_file "$FONT_URL" "$tmp_file" && [ -s "$tmp_file" ]; then
            local size=$(stat -c%s "$tmp_file" 2>/dev/null || echo 0)
            if [ "$size" -gt 50000 ] && python3 -c "from PIL import ImageFont; ImageFont.truetype('$tmp_file', 24)" 2>/dev/null; then
                sudo mkdir -p "$(dirname "$font")"; sudo cp "$tmp_file" "$font"
                sudo chown "$USER:$USER" "$font" 2>/dev/null || true; sudo chmod 644 "$font" 2>/dev/null || true
                rm -f "$tmp_file"; log_ok "Шрифт: скачан и валиден ($size байт)"; return 0
            else log_warn "Шрифт: проблема с загрузкой через PIL"; fi
        else log_err "Шрифт: не удалось скачать"; fi
        rm -f "$tmp_file" 2>/dev/null; return 1
    fi
    local size=$(stat -c%s "$font" 2>/dev/null || echo 0)
    if [ "$size" -gt 50000 ]; then
        log_ok "Шрифт: $size байт (валидный)"
        python3 -c "from PIL import ImageFont; ImageFont.truetype('$font', 24)" 2>/dev/null && { log_ok "Шрифт: загружается через PIL"; return 0; } || { log_warn "Шрифт: не загружается через PIL"; return 1; }
    else log_err "Шрифт: слишком мал"; return 1; fi
}

check_systemd_service() {
    log_check "Проверка systemd сервиса..."
    if [ ! -f "$SERVICE_FILE" ]; then
        log_warn "Сервис: файл не найден, пробуем скачать..."
        local tmp_service="/tmp/mbcloud_service_$$.service"
        if download_file "$SERVICE_URL" "$tmp_service"; then
            sudo cp "$tmp_service" "$SERVICE_FILE"
            sudo sed -i "s/User=.*/User=$USER/; s|WorkingDirectory=.*|WorkingDirectory=$REPO_PATH/display|; s|ExecStart=.*|ExecStart=/usr/bin/python3 $REPO_PATH/display/main.py|" "$SERVICE_FILE"
            sudo systemctl daemon-reload; sudo systemctl enable mbcloud-display.service 2>/dev/null || true
            rm -f "$tmp_service"; log_ok "Сервис: скачан и настроен"
        else log_err "Сервис: не удалось скачать"; return 1; fi
    fi
    log_ok "Сервис: файл $SERVICE_FILE существует"
    sudo systemctl is-enabled mbcloud-display.service &>/dev/null && log_ok "Сервис: включён в автозагрузку" || log_warn "Сервис: не включён в автозагрузку"
    sudo systemctl is-active mbcloud-display.service &>/dev/null && { log_ok "Сервис: активен"; return 0; } || { log_warn "Сервис: не активен"; return 0; }
}

check_gpio_interfaces() {
    log_check "Проверка интерфейсов GPIO..."
    [ -c /dev/spidev0.0 ] && log_ok "SPI: /dev/spidev0.0 доступен" || log_warn "SPI: /dev/spidev0.0 не найден"
    [ -c /dev/i2c-1 ] && { log_ok "I2C: /dev/i2c-1 доступен"; command -v i2cdetect &>/dev/null && { sudo i2cdetect -y 1 2>/dev/null | grep -qE "51|68" && log_ok "RTC: обнаружен" || log_warn "RTC: не обнаружен"; }; } || log_warn "I2C: /dev/i2c-1 не найден"
}

check_python_packages() {
    log_check "Проверка Python-зависимостей..."
    local missing=()
    for pkg in psutil gpiozero PIL numpy; do
        python3 -c "import $pkg" 2>/dev/null && log_ok "Python: $pkg установлен" || { missing+=("$pkg"); log_warn "Python: $pkg не найден"; }
    done
    [ ${#missing[@]} -eq 0 ] && return 0 || { log_warn "Отсутствуют: ${missing[*]}"; log "Установите: sudo apt install -y python3-psutil python3-gpiozero python3-pil python3-numpy"; return 1; }
}

check_waveshare_demo() {
    log_check "Проверка демо-кода Waveshare..."
    local lcdconfig="/home/$USER/CM4-NAS-Double-Deck_Demo/RaspberryPi/lib/lcdconfig.py"
    if [ -f "$lcdconfig" ]; then
        log_ok "Демо-код: lcdconfig.py найден"
        grep -q "^#.*self\.FAN_PIN = self\.gpio_pwm" "$lcdconfig" 2>/dev/null && log_ok "Демо-код: конфликт GPIO 19 исправлен" || log_warn "Демо-код: возможна проблема с GPIO 19"
        return 0
    else log_warn "Демо-код: lcdconfig.py не найден"; return 0; fi
}

check_storage() {
    log_check "Проверка хранилища..."
    for dir in /mnt/disk1 /mnt/disk2 "$DATA_MOUNT"; do [ -d "$dir" ] && log_ok "Хранилище: $dir существует" || log_warn "Хранилище: $dir не существует"; done
    [ -d "$DATA_MOUNT" ] && { owner=$(stat -c%U "$DATA_MOUNT" 2>/dev/null); [ "$owner" = "$USER" ] && log_ok "Хранилище: права корректны" || log_warn "Хранилище: владелец=$owner"; }
    sudo grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null && log_ok "MergerFS: настроен" || log_warn "MergerFS: не настроен (опционально)"
    return 0
}

check_samba() {
    log_check "Проверка Samba..."
    command -v smbpasswd &>/dev/null && { log_ok "Samba: установлен"; sudo grep -q "^\[mbcloud\]" /etc/samba/smb.conf 2>/dev/null && log_ok "Samba: share настроен" || log_warn "Samba: share не настроен"; sudo systemctl is-active smbd &>/dev/null && log_ok "Samba: сервис активен" || log_warn "Samba: сервис не активен"; return 0; } || { log_warn "Samba: не установлен"; return 0; }
}

check_docker() {
    log_check "Проверка Docker..."
    if command -v docker &>/dev/null && (command -v docker-compose &>/dev/null || docker compose version &>/dev/null); then
        log_ok "Docker: установлен"; [ -f "$REPO_PATH/docker/docker-compose.yml" ] && log_ok "Docker: docker-compose.yml найден" || log_warn "Docker: docker-compose.yml не найден"; return 0
    else log_warn "Docker: не установлен (опционально)"; return 0; fi
}

check_network() {
    log_check "Проверка сети..."
    local ip=$(hostname -I | awk '{print $1}')
    if [ -n "$ip" ]; then
        log_ok "Сеть: IP адрес $ip"
        sudo ss -tlnp 2>/dev/null | grep -q ":2283 " && log_ok "Сеть: порт 2283 слушается" || log_warn "Сеть: порт 2283 не слушается"
        return 0
    else log_warn "Сеть: не удалось определить IP"; return 1; fi
}

print_verification_summary() {
    echo ""; echo -e "${CYAN}${BOLD}═══════════════════════════════════════${NC}"; echo -e "${CYAN}${BOLD}  ПРОВЕРКА УСТАНОВКИ${NC}"; echo -e "${CYAN}${BOLD}═══════════════════════════════════════${NC}"; echo ""
    echo -e "${BOLD}Результаты:${NC}"; echo -e "  ${GREEN}✓ Прошло:${NC} $CHECKS_PASSED"; echo -e "  ${YELLOW}⚠ Предупреждения:${NC} $CHECKS_SKIPPED"; echo -e "  ${RED}✗ Ошибки:${NC} $CHECKS_FAILED"; echo ""
    [ $CHECKS_FAILED -eq 0 ] && { echo -e "${GREEN}${BOLD}🎉 ВСЕ КРИТИЧЕСКИЕ ПРОВЕРКИ ПРОЙДЕНЫ!${NC}"; echo "Система готова к использованию."; } || { echo -e "${RED}${BOLD}⚠ ЕСТЬ ОШИБКИ${NC}"; echo "Исправьте $CHECKS_FAILED ошибок."; }
    echo ""; echo -e "${BOLD}Полезные команды:${NC}"; echo -e "  • Перезапуск: ${BLUE}sudo systemctl restart mbcloud-display.service${NC}"; echo -e "  • Логи: ${BLUE}journalctl -u mbcloud-display.service -f${NC}"; echo -e "  • Immich: ${BLUE}cd ~/mbcloud-system/docker && docker compose up -d${NC}"; echo -e "  • Samba: ${BLUE}sudo smbpasswd -a $USER${NC}"; echo -e "  • Reboot: ${BLUE}sudo reboot${NC}"; echo ""
}

run_all_checks() {
    header "Проверка установленных компонентов"
    check_python_syntax || true; check_font_file || true; check_systemd_service || true; check_gpio_interfaces || true
    check_python_packages || true; check_waveshare_demo || true; check_storage || true; check_samba || true; check_docker || true; check_network || true
    print_verification_summary; return $CHECKS_FAILED
}

#===============================================================================
# 🔧 ФУНКЦИИ УСТАНОВКИ
#===============================================================================

check_prerequisites() {
    header "Проверка системы"
    [[ $EUID -ne 0 ]] && { log_err "Запустите с: curl ... | sudo bash"; exit 1; }
    grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null || { log_warn "Не Raspberry Pi — продолжение на свой риск"; read -p "Продолжить? (y/N): " -n 1 -r; echo; [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1; }
    log_ok "Система: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
}

update_system() { header "Обновление системы"; log "Обновляем пакеты..."; sudo apt update -qq && sudo apt upgrade -y -qq; log_ok "Система обновлена"; }

install_packages() {
    header "Установка зависимостей"
    log "Устанавливаем базовые пакеты..."
    sudo apt install -y -qq git curl wget unzip htop tmux python3-pip python3-venv mergerfs smartmontools samba i2c-tools read-edid fonts-dejavu-core libatlas-base-dev libopenjp2-7 libtiff5 2>/dev/null || log_warn "Некоторые пакеты могли не установиться"
    
    log "Устанавливаем Python-зависимости (включая numpy для дисплея)..."
    sudo apt install -y -qq python3-psutil python3-gpiozero python3-pil python3-numpy 2>/dev/null || \
    sudo pip3 install -q --break-system-packages psutil gpiozero Pillow numpy 2>/dev/null || \
    log_warn "Некоторые Python-пакеты могли не установиться"
    log_ok "Зависимости установлены"
}

configure_boot() {
    header "Настройка /boot/firmware/config.txt"
    
    [ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"
    
    # 🔧 РЕЗЕРВНАЯ КОПИЯ
    sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M)" 2>/dev/null || true
    log "Резервная копия: ${CONFIG_FILE}.backup.*"
    
    # 🔧 СКАЧИВАЕМ И ЗАМЕНЯЕМ ПОЛНОСТЬЮ
    log "Скачиваем чистый config.txt с GitHub..."
    local tmp_config="/tmp/mbcloud_config_$$.txt"
    
    if download_file "$CONFIG_CLEAN_URL" "$tmp_config"; then
        # Заменяем файл полностью
        sudo cp "$tmp_config" "$CONFIG_FILE"
        sudo chown root:root "$CONFIG_FILE"
        sudo chmod 644 "$CONFIG_FILE"
        rm -f "$tmp_config"
        log_ok "config.txt заменён на чистую версию"
        log "⚠️  Требуется перезагрузка для применения изменений!"
    else
        log_warn "Не удалось скачать config.txt.clean, пробуем умное добавление..."
        # Fallback: добавляем только недостающее (старый метод)
        sudo bash -c "grep -q '^dtparam=spi=on' '$CONFIG_FILE' || echo 'dtparam=spi=on' >> '$CONFIG_FILE'"
        sudo bash -c "grep -q '^dtparam=i2c_arm=on' '$CONFIG_FILE' || echo 'dtparam=i2c_arm=on' >> '$CONFIG_FILE'"
        sudo bash -c "grep -q 'dtoverlay=i2c-rtc,pcf85063a' '$CONFIG_FILE' || echo 'dtoverlay=i2c-rtc,pcf85063a' >> '$CONFIG_FILE'"
        sudo sed -i 's/^dtparam=audio=on/dtparam=audio=off/' "$CONFIG_FILE" 2>/dev/null || true
        log_ok "Настройки добавлены (fallback)"
    fi
}

download_waveshare_demo() {
    header "Скачивание демо-кода Waveshare"
    cd /home/$USER
    if [ ! -d "CM4-NAS-Double-Deck_Demo" ]; then
        log "Скачиваем демо-код..."; wget -q -O demo.zip "$WAVESHARE_URL"; unzip -q demo.zip; rm -f demo.zip; log_ok "Демо-код скачан"
    else log_ok "Демо-код уже присутствует"; fi
    local lcdconfig="/home/$USER/CM4-NAS-Double-Deck_Demo/RaspberryPi/lib/lcdconfig.py"
    if [ -f "$lcdconfig" ]; then
        log "Исправляем конфликт GPIO 19..."
        sudo sed -i 's/self\.FAN_PIN = self\.gpio_pwm/# self.FAN_PIN = self.gpio_pwm/g; s/self\.FAN_PIN\.value = 0/# self.FAN_PIN.value = 0/g; s/self\.FAN_PIN\.close()/# self.FAN_PIN.close()/g' "$lcdconfig"
        sudo rm -rf "$(dirname "$lcdconfig")/__pycache__" 2>/dev/null || true
        log_ok "lcdconfig.py исправлен"
    fi
}

clone_repository() {
    header "Клонирование репозитория"
    if [ -d "$REPO_PATH/.git" ]; then
        log "Обновляем репозиторий..."; cd "$REPO_PATH" && git pull -q
    else
        log "Клонируем репозиторий..."
        sudo -u "$USER" git clone -b "$REPO_BRANCH" "$REPO_URL" "$REPO_PATH" 2>/dev/null || { sudo mkdir -p "$REPO_PATH"/{display/fonts,scripts,systemd,docker,config,docs}; sudo chown -R "$USER:$USER" "$REPO_PATH"; }
    fi
    sudo chmod +x "$REPO_PATH/scripts/"*.sh 2>/dev/null || true; log_ok "Репозиторий готов"
}

download_main_py() {
    header "Скачивание main.py с GitHub"
    local tmp_file="/tmp/mbcloud_main_$$.py"
    if download_file "$MAIN_PY_URL" "$tmp_file" && [ -s "$tmp_file" ]; then
        sudo mkdir -p "$REPO_PATH/display"; sudo cp "$tmp_file" "$REPO_PATH/display/main.py"
        sudo chown "$USER:$USER" "$REPO_PATH/display/main.py" 2>/dev/null || true; sudo chmod 644 "$REPO_PATH/display/main.py" 2>/dev/null || true
        rm -f "$tmp_file"
        python3 -m py_compile "$REPO_PATH/display/main.py" 2>/dev/null && log_ok "main.py скачан и проверен" || { log_err "Ошибка синтаксиса"; return 1; }
    else log_err "Не удалось скачать main.py"; rm -f "$tmp_file" 2>/dev/null; return 1; fi
}

setup_fonts() {
    header "Настройка шрифтов"
    local tmp_file="/tmp/mbcloud_font_$$.ttf"
    sudo mkdir -p "$REPO_PATH/display/fonts"
    if [ ! -s "$REPO_PATH/display/fonts/baveuse_0.ttf" ]; then
        log "Скачиваем шрифт..."
        if download_file "$FONT_URL" "$tmp_file" && [ -s "$tmp_file" ]; then
            sudo cp "$tmp_file" "$REPO_PATH/display/fonts/baveuse_0.ttf"
            sudo chown "$USER:$USER" "$REPO_PATH/display/fonts/baveuse_0.ttf" 2>/dev/null || true; sudo chmod 644 "$REPO_PATH/display/fonts/baveuse_0.ttf" 2>/dev/null || true
            rm -f "$tmp_file"
        fi
    fi
    if [ -s "$REPO_PATH/display/fonts/baveuse_0.ttf" ]; then
        local size=$(sudo stat -c%s "$REPO_PATH/display/fonts/baveuse_0.ttf" 2>/dev/null || echo 0)
        log_ok "Шрифт установлен: $size байт"
    else log_warn "Шрифт не установлен"; fi
    sudo chown -R "$USER:$USER" "$REPO_PATH/display/fonts" 2>/dev/null || true
}

setup_systemd_service() {
    header "Настройка systemd сервиса"
    local tmp_service="/tmp/mbcloud_service_$$.service"
    if download_file "$SERVICE_URL" "$tmp_service"; then
        sudo cp "$tmp_service" "$SERVICE_FILE"
        sudo sed -i "s/User=.*/User=$USER/; s|WorkingDirectory=.*|WorkingDirectory=$REPO_PATH/display|; s|ExecStart=.*|ExecStart=/usr/bin/python3 $REPO_PATH/display/main.py|" "$SERVICE_FILE"
        sudo systemctl daemon-reload; sudo systemctl enable mbcloud-display.service 2>/dev/null || true
        rm -f "$tmp_service"; log_ok "Сервис настроен и включён в автозагрузку"
    else log_err "Не удалось скачать mbcloud-display.service"; return 1; fi
}

setup_storage() {
    header "Настройка хранилища"
    sudo mkdir -p /mnt/disk1 /mnt/disk2 "$DATA_MOUNT"
    sudo grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null && log_ok "MergerFS настроен" || log_warn "MergerFS не в fstab (настройте вручную)"
    for dir in photos import immich-postgres immich-redis backups; do sudo mkdir -p "$DATA_MOUNT/$dir"; done
    sudo chown -R "$USER:$USER" "$DATA_MOUNT" 2>/dev/null || true; log_ok "Хранилище настроено"
}

setup_samba() {
    header "Настройка Samba"
    command -v smbpasswd &>/dev/null || { log "Устанавливаем Samba..."; sudo apt install -y -qq samba 2>/dev/null || log_warn "Не удалось установить Samba"; }
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
        log_ok "Samba share добавлен"; sudo systemctl restart smbd 2>/dev/null || true; sudo systemctl enable smbd 2>/dev/null || true
    else log_ok "Samba share уже настроен"; fi
    log "Задайте пароль: sudo smbpasswd -a $USER"
}

finalize() {
    header "✅ Установка завершена!"
    run_all_checks
    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  mbcloud NAS ГОТОВ!  ${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"
    echo ""
    echo -e "${GREEN}Следующие шаги:${NC}"
    echo -e "  1. ${RED}ПЕРЕЗАГРУЗКА ОБЯЗАТЕЛЬНА${NC}: ${YELLOW}sudo reboot${NC} (для применения config.txt!)"
    echo -e "  2. Immich: ${YELLOW}cd ~/mbcloud-system/docker && docker compose up -d${NC}"
    echo -e "  3. Samba: ${YELLOW}sudo smbpasswd -a $USER${NC}"
    echo -e "  4. iPhone: ${YELLOW}http://$(hostname -I | awk '{print $1}'):2283${NC}"
    echo ""
    echo -e "${YELLOW}Полезные команды:${NC}"
    echo -e "  • Статус: ${BLUE}sudo systemctl status mbcloud-display.service${NC}"
    echo -e "  • Логи: ${BLUE}journalctl -u mbcloud-display.service -f${NC}"
    echo -e "  • Temp: ${BLUE}vcgencmd measure_temp${NC}"
    echo ""
    read -p "Перезагрузить СЕЙЧАС? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && { log "Перезагрузка..."; sudo reboot; } || { log_warn "⚠️  НЕ ЗАБУДЬТЕ: ${YELLOW}sudo reboot${NC} (иначе SPI/I2C не заработают)!"; }
}

main() {
    header "mbcloud NAS Auto-Setup v2.8"
    check_prerequisites; update_system; install_packages; configure_boot
    download_waveshare_demo; clone_repository; download_main_py; setup_fonts
    setup_systemd_service; setup_storage; setup_samba; finalize
}

[[ "${1:-}" == "--check" || "${1:-}" == "-c" ]] && { run_all_checks; exit $?; }
main "$@"
