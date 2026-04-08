#!/bin/bash
#===============================================================================
# mbcloud NAS - Полный скрипт установки (v2.5 - универсальная загрузка)
# Использование:
#   • Установка:  curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash
#   • Проверка:   curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash -s -- --check
#===============================================================================

set -e

# 🎨 Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

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
CHECKS_PASSED=0; CHECKS_FAILED=0; CHECKS_SKIPPED=0

# 📢 Функции вывода
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; ((CHECKS_PASSED++)); }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; ((CHECKS_SKIPPED++)); }
log_err() { echo -e "${RED}[✗]${NC} $1"; ((CHECKS_FAILED++)); }
log_check() { echo -e "${CYAN}[→]${NC} $1"; }

header() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  mbcloud NAS Setup v2.5            ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════╝${NC}"
    echo "  $(date '+%Y-%m-%d %H:%M:%S') | User: $USER"
    echo ""
}

#===============================================================================
# 🔧 УНИВЕРСАЛЬНАЯ ФУНКЦИЯ СКАЧИВАНИЯ (3 метода + проверка)
#===============================================================================
download_file() {
    local url="$1"
    local dest="$2"
    local tmp="/tmp/mbcloud_dl_$$.tmp"
    local http_code=""
    
    # Метод 1: curl с проверкой HTTP кода
    if command -v curl &>/dev/null; then
        http_code=$(curl -sSL --connect-timeout 10 --max-time 30 -w "%{http_code}" -o "$tmp" "$url" 2>/dev/null)
        if [ "$http_code" = "200" ] && [ -s "$tmp" ]; then
            mv "$tmp" "$dest" 2>/dev/null && return 0
        fi
    fi
    
    # Метод 2: wget как fallback
    if command -v wget &>/dev/null; then
        if wget -q --timeout=30 -O "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
            mv "$tmp" "$dest" 2>/dev/null && return 0
        fi
    fi
    
    # Метод 3: curl + sudo tee (для обхода проблем с правами)
    if command -v curl &>/dev/null; then
        if curl -sSL --connect-timeout 10 --max-time 30 "$url" 2>/dev/null | sudo tee "$tmp" > /dev/null && [ -s "$tmp" ]; then
            sudo mv "$tmp" "$dest" 2>/dev/null && return 0
        fi
    fi
    
    # Очистка
    rm -f "$tmp" 2>/dev/null
    return 1
}

#===============================================================================
# ✅ ПРОВЕРКИ КОМПОНЕНТОВ (с авто-восстановлением)
#===============================================================================

check_python_syntax() {
    log_check "Проверка синтаксиса main.py..."
    local main_py="$REPO_PATH/display/main.py"
    
    if [ ! -f "$main_py" ]; then
        log_warn "main.py: файл не найден, пробуем скачать..."
        local tmp_file="/tmp/mbcloud_main_$$.py"
        
        if download_file "$MAIN_PY_URL" "$tmp_file"; then
            # Проверяем, что это действительно Python-файл
            if head -1 "$tmp_file" 2>/dev/null | grep -q "^#!.*python"; then
                if python3 -m py_compile "$tmp_file" 2>/dev/null; then
                    sudo mkdir -p "$(dirname "$main_py")"
                    sudo cp "$tmp_file" "$main_py"
                    sudo chown "$USER:$USER" "$main_py" 2>/dev/null || true
                    sudo chmod 644 "$main_py" 2>/dev/null || true
                    rm -f "$tmp_file"
                    log_ok "main.py: скачан и проверен"
                    return 0
                else
                    log_err "main.py: ошибка синтаксиса в скачанном файле"
                fi
            else
                log_err "main.py: скачан, но это не Python-файл"
            fi
        else
            log_err "main.py: не удалось скачать (сеть/сервер)"
        fi
        rm -f "$tmp_file" 2>/dev/null
        log "Ручная загрузка: curl -sSL $MAIN_PY_URL | sudo tee $main_py > /dev/null"
        return 1
    fi
    
    # Файл уже есть — проверяем синтаксис
    if python3 -m py_compile "$main_py" 2>/dev/null; then
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
    
    if [ ! -f "$font" ]; then
        log_warn "Шрифт: не найден, пробуем скачать..."
        local tmp_file="/tmp/mbcloud_font_$$.ttf"
        
        if download_file "$FONT_URL" "$tmp_file"; then
            if [ -s "$tmp_file" ]; then
                local size=$(stat -c%s "$tmp_file" 2>/dev/null || echo 0)
                if [ "$size" -gt 50000 ]; then
                    if python3 -c "from PIL import ImageFont; ImageFont.truetype('$tmp_file', 24)" 2>/dev/null; then
                        sudo mkdir -p "$(dirname "$font")"
                        sudo cp "$tmp_file" "$font"
                        sudo chown "$USER:$USER" "$font" 2>/dev/null || true
                        sudo chmod 644 "$font" 2>/dev/null || true
                        rm -f "$tmp_file"
                        log_ok "Шрифт: скачан и валиден ($size байт)"
                        return 0
                    else
                        log_warn "Шрифт: скачан, но не загружается через PIL"
                    fi
                else
                    log_err "Шрифт: скачан, но слишком мал ($size байт)"
                fi
            else
                log_err "Шрифт: скачан, но пустой"
            fi
        else
            log_err "Шрифт: не удалось скачать"
        fi
        rm -f "$tmp_file" 2>/dev/null
        log "Ручная загрузка: curl -sSL $FONT_URL | sudo tee $font > /dev/null"
        return 1
    fi
    
    # Файл есть — проверяем
    local size=$(stat -c%s "$font" 2>/dev/null || echo 0)
    if [ "$size" -gt 50000 ]; then
        log_ok "Шрифт: $size байт (валидный)"
        if python3 -c "from PIL import ImageFont; ImageFont.truetype('$font', 24)" 2>/dev/null; then
            log_ok "Шрифт: загружается через PIL"
            return 0
        else
            log_warn "Шрифт: не загружается через PIL"
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
        sudo systemctl is-enabled mbcloud-display.service &>/dev/null && log_ok "Сервис: включён в автозагрузку" || log_warn "Сервис: не включён в автозагрузку"
        sudo systemctl is-active mbcloud-display.service &>/dev/null && { log_ok "Сервис: активен (running)"; return 0; } || { log_warn "Сервис: не активен"; return 0; }
    else
        log_err "Сервис: файл не найден"; return 1
    fi
}

check_gpio_interfaces() {
    log_check "Проверка интерфейсов GPIO..."
    [ -c /dev/spidev0.0 ] && log_ok "SPI: /dev/spidev0.0 доступен" || log_warn "SPI: /dev/spidev0.0 не найден"
    if [ -c /dev/i2c-1 ]; then
        log_ok "I2C: /dev/i2c-1 доступен"
        command -v i2cdetect &>/dev/null && { sudo i2cdetect -y 1 2>/dev/null | grep -qE "51|68" && log_ok "RTC: обнаружен" || log_warn "RTC: не обнаружен"; }
    else
        log_warn "I2C: /dev/i2c-1 не найден"
    fi
}

check_python_packages() {
    log_check "Проверка Python-зависимостей..."
    local missing=()
    for pkg in psutil gpiozero PIL; do
        python3 -c "import $pkg" 2>/dev/null && log_ok "Python: $pkg установлен" || { missing+=("$pkg"); log_warn "Python: $pkg не найден"; }
    done
    [ ${#missing[@]} -eq 0 ] && return 0 || { log_warn "Отсутствуют: ${missing[*]}"; log "Установите: sudo pip3 install --break-system-packages ${missing[*]}"; return 1; }
}

check_waveshare_demo() {
    log_check "Проверка демо-кода Waveshare..."
    local lcdconfig="/home/$USER/CM4-NAS-Double-Deck_Demo/RaspberryPi/lib/lcdconfig.py"
    if [ -f "$lcdconfig" ]; then
        log_ok "Демо-код: lcdconfig.py найден"
        grep -q "^#.*self\.FAN_PIN = self\.gpio_pwm" "$lcdconfig" 2>/dev/null && log_ok "Демо-код: конфликт GPIO 19 исправлен" || log_warn "Демо-код: возможна проблема с GPIO 19"
        return 0
    else
        log_warn "Демо-код: lcdconfig.py не найден"; return 0
    fi
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
        log_ok "Docker: установлен"
        [ -f "$REPO_PATH/docker/docker-compose.yml" ] && log_ok "Docker: docker-compose.yml найден" || log_warn "Docker: docker-compose.yml не найден"
        return 0
    else
        log_warn "Docker: не установлен (опционально)"; return 0
    fi
}

check_network() {
    log_check "Проверка сети..."
    local ip=$(hostname -I | awk '{print $1}')
    if [ -n "$ip" ]; then
        log_ok "Сеть: IP адрес $ip"
        sudo ss -tlnp 2>/dev/null | grep -q ":2283 " && log_ok "Сеть: порт 2283 слушается" || log_warn "Сеть: порт 2283 не слушается"
        return 0
    else
        log_warn "Сеть: не удалось определить IP"; return 1
    fi
}

print_verification_summary() {
    echo ""; echo -e "${CYAN}${BOLD}═══════════════════════════════════════${NC}"; echo -e "${CYAN}${BOLD}  ПРОВЕРКА УСТАНОВКИ${NC}"; echo -e "${CYAN}${BOLD}═══════════════════════════════════════${NC}"; echo ""
    echo -e "${BOLD}Результаты:${NC}"; echo -e "  ${GREEN}✓ Прошло:${NC} $CHECKS_PASSED"; echo -e "  ${YELLOW}⚠ Предупреждения:${NC} $CHECKS_SKIPPED"; echo -e "  ${RED}✗ Ошибки:${NC} $CHECKS_FAILED"; echo ""
    if [ $CHECKS_FAILED -eq 0 ]; then echo -e "${GREEN}${BOLD}🎉 ВСЕ КРИТИЧЕСКИЕ ПРОВЕРКИ ПРОЙДЕНЫ!${NC}"; echo "Система готова к использованию."; else echo -e "${RED}${BOLD}⚠ ЕСТЬ ОШИБКИ${NC}"; echo "Исправьте $CHECKS_FAILED ошибок."; fi
    echo ""; echo -e "${BOLD}Полезные команды:${NC}"; echo "  • Перезапуск: ${BLUE}sudo systemctl restart mbcloud-display.service${NC}"; echo "  • Логи: ${BLUE}journalctl -u mbcloud-display.service -f${NC}"; echo "  • Immich: ${BLUE}cd ~/mbcloud-system/docker && docker compose up -d${NC}"; echo "  • Samba: ${BLUE}sudo smbpasswd -a $USER${NC}"; echo "  • Reboot: ${BLUE}sudo reboot${NC}"; echo ""
}

run_all_checks() {
    header "Проверка установленных компонентов"
    check_python_syntax; check_font_file; check_systemd_service; check_gpio_interfaces; check_python_packages; check_waveshare_demo; check_storage; check_samba; check_docker; check_network
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
    log "Устанавливаем Python-зависимости..."
    sudo pip3 install -q --break-system-packages psutil>=5.9.0 gpiozero>=2.0 Pillow>=9.0.0 2>/dev/null || log_warn "Некоторые Python-пакеты могли не установиться"
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
        log "Скачиваем демо-код..."; wget -q -O demo.zip "$WAVESHARE_URL"; unzip -q demo.zip; rm -f demo.zip; log_ok "Демо-код скачан"
    else
        log_ok "Демо-код уже присутствует"
    fi
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
        sudo mkdir -p "$REPO_PATH/display"
        sudo cp "$tmp_file" "$REPO_PATH/display/main.py"
        sudo chown "$USER:$USER" "$REPO_PATH/display/main.py" 2>/dev/null || true
        sudo chmod 644 "$REPO_PATH/display/main.py" 2>/dev/null || true
        rm -f "$tmp_file"
        python3 -m py_compile "$REPO_PATH/display/main.py" 2>/dev/null && log_ok "main.py скачан и проверен" || { log_err "Ошибка синтаксиса"; return 1; }
    else
        log_err "Не удалось скачать main.py"; rm -f "$tmp_file" 2>/dev/null; return 1
    fi
}

setup_fonts() {
    header "Настройка шрифтов"
    local tmp_file="/tmp/mbcloud_font_$$.ttf"
    sudo mkdir -p "$REPO_PATH/display/fonts"
    if [ ! -s "$REPO_PATH/display/fonts/baveuse_0.ttf" ]; then
        log "Скачиваем шрифт..."
        if download_file "$FONT_URL" "$tmp_file" && [ -s "$tmp_file" ]; then
            sudo cp "$tmp_file" "$REPO_PATH/display/fonts/baveuse_0.ttf"
            sudo chown "$USER:$USER" "$REPO_PATH/display/fonts/baveuse_0.ttf" 2>/dev/null || true
            sudo chmod 644 "$REPO_PATH/display/fonts/baveuse_0.ttf" 2>/dev/null || true
            rm -f "$tmp_file"
        fi
    fi
    if [ -s "$REPO_PATH/display/fonts/baveuse_0.ttf" ]; then
        local size=$(sudo stat -c%s "$REPO_PATH/display/fonts/baveuse_0.ttf" 2>/dev/null || echo 0)
        log_ok "Шрифт установлен: $size байт"
    else
        log_warn "Шрифт не установлен"
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
    sudo systemctl daemon-reload; sudo systemctl enable mbcloud-display.service 2>/dev/null || true; log_ok "Сервис настроен"
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
    else
        log_ok "Samba share уже настроен"
    fi
    log "Задайте пароль: sudo smbpasswd -a $USER"
}

finalize() {
    header "✅ Установка завершена!"
    run_all_checks
    echo ""; echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"; echo -e "${GREEN}${BOLD}  mbcloud NAS ГОТОВ!  ${NC}"; echo -e "${GREEN}${BOLD}═══════════════════════════════════════${NC}"; echo ""
    echo -e "${GREEN}Следующие шаги:${NC}"; echo "  1. Перезагрузка: ${YELLOW}sudo reboot${NC}"; echo "  2. Immich: ${YELLOW}cd ~/mbcloud-system/docker && docker compose up -d${NC}"; echo "  3. Samba: ${YELLOW}sudo smbpasswd -a $USER${NC}"; echo "  4. iPhone: ${YELLOW}http://$(hostname -I | awk '{print $1}'):2283${NC}"; echo ""
    echo -e "${YELLOW}Полезные команды:${NC}"; echo "  • Статус: ${BLUE}sudo systemctl status mbcloud-display.service${NC}"; echo "  • Логи: ${BLUE}journalctl -u mbcloud-display.service -f${NC}"; echo "  • Temp: ${BLUE}vcgencmd measure_temp${NC}"; echo ""
    read -p "Перезагрузить сейчас? (y/N): " -n 1 -r; echo; [[ $REPLY =~ ^[Yy]$ ]] && { log "Перезагрузка..."; sudo reboot; } || log_warn "Не забудьте: ${YELLOW}sudo reboot${NC}"
}

main() { header "mbcloud NAS Auto-Setup v2.5"; check_prerequisites; update_system; install_packages; configure_boot; download_waveshare_demo; clone_repository; download_main_py; setup_fonts; setup_systemd_service; setup_storage; setup_samba; finalize; }

[[ "${1:-}" == "--check" || "${1:-}" == "-c" ]] && { run_all_checks; exit $?; }
main "$@"
