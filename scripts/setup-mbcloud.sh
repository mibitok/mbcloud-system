#!/bin/bash
#===============================================================================
# mbcloud NAS - Автоматическая настройка системы
# Для: Raspberry Pi CM4 + Waveshare CM4-NAS-Double-Deck
# Использование: curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash
#===============================================================================

set -e  # Выход при ошибке

# 🎨 Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ⚙️ Конфигурация
REPO_URL="https://github.com/mibitok/mbcloud-system.git"
REPO_PATH="/home/${SUDO_USER:-mibitok}/mbcloud-system"
CONFIG_FILE="/boot/firmware/config.txt"
DATA_MOUNT="/DATA"
DISK1="/dev/sda1"
DISK2="/dev/sdb1"
MOUNT1="/mnt/disk1"
MOUNT2="/mnt/disk2"

# ============================================================================
# 📢 ФУНКЦИИ ВЫВОДА
# ============================================================================
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}  mbcloud NAS Setup - $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo ""
}

# ============================================================================
# 🔍 ПРОВЕРКА ПРАВ И СИСТЕМЫ
# ============================================================================
check_prerequisites() {
    header "Проверка системы"
    
    if [[ $EUID -ne 0 ]]; then
        log_error "Запустите скрипт с sudo: sudo bash $0"
        exit 1
    fi
    
    if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
        log_warn "Скрипт разработан для Raspberry Pi. Продолжение на свой страх и риск."
        read -p "Продолжить? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    
    log_success "Система: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
}

# ============================================================================
# ⚙️ НАСТРОЙКА /boot/firmware/config.txt (ГЛАВНОЕ!)
# ============================================================================
configure_display() {
    header "Настройка дисплея и интерфейсов"
    
    log_info "Редактируем $CONFIG_FILE"
    
    # Создаём резервную копию
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup.$(date +%Y%m%d%H%M)"
    log_success "Backup создан: ${CONFIG_FILE}.backup.*"
    
    # Включаем SPI для дисплея
    if ! grep -q "^dtparam=spi=on" "$CONFIG_FILE"; then
        echo "dtparam=spi=on" >> "$CONFIG_FILE"
        log_success "✓ SPI enabled"
    else
        log_info "SPI уже включён"
    fi
    
    # Включаем I2C для RTC (PCF85063a)
    if ! grep -q "^dtparam=i2c_arm=on" "$CONFIG_FILE"; then
        echo "dtparam=i2c_arm=on" >> "$CONFIG_FILE"
        log_success "✓ I2C enabled"
    else
        log_info "I2C уже включён"
    fi
    
    # Добавляем драйвер RTC
    if ! grep -q "dtoverlay=i2c-rtc,pcf85063a" "$CONFIG_FILE"; then
        echo "" >> "$CONFIG_FILE"
        echo "# RTC PCF85063a для CM4-NAS-Double-Deck" >> "$CONFIG_FILE"
        echo "dtoverlay=i2c-rtc,pcf85063a" >> "$CONFIG_FILE"
        log_success "✓ RTC overlay added"
    else
        log_info "RTC overlay уже настроен"
    fi
    
    # Отключаем аудио (если не нужно) для освобождения ресурсов
    if ! grep -q "^#dtparam=audio=on" "$CONFIG_FILE" && ! grep -q "^dtparam=audio=off" "$CONFIG_FILE"; then
        echo "# Audio disabled for mbcloud NAS" >> "$CONFIG_FILE"
        echo "dtparam=audio=off" >> "$CONFIG_FILE"
        log_info "✓ Audio disabled (опционально)"
    fi
    
    # Настройка дисплея (если требуется специфичная инициализация)
    # Для Waveshare 2.4" IPS обычно достаточно SPI, но можно добавить:
    # dtoverlay=spi0-1cs  # если нужны оба CS пина
    
    log_success "Конфигурация дисплея обновлена"
}

# ============================================================================
# 💾 ОБНАРУЖЕНИЕ И НАСТРОЙКА ДИСКОВ
# ============================================================================
configure_storage() {
    header "Настройка хранилища"
    
    # Функция проверки диска
    check_disk() {
        local disk=$1
        local name=$2
        if lsblk "$disk" &>/dev/null; then
            log_info "✓ $name найден: $disk"
            return 0
        else
            log_warn "✗ $name не найден: $disk"
            return 1
        fi
    }
    
    # Проверяем наличие дисков
    DISK1_FOUND=false
    DISK2_FOUND=false
    check_disk "$DISK1" "SATA Disk 1" && DISK1_FOUND=true
    check_disk "$DISK2" "SATA Disk 2" && DISK2_FOUND=true
    
    if ! $DISK1_FOUND && ! $DISK2_FOUND; then
        log_warn "Диски SATA не обнаружены. Пропускаем настройку хранения."
        return 0
    fi
    
    # Запрос на форматирование (БЕЗОПАСНОСТЬ!)
    echo ""
    log_warn "ВНИМАНИЕ: Следующие действия могут УДАЛИТЬ ДАННЫЕ!"
    echo "  Disk 1: $DISK1"
    echo "  Disk 2: $DISK2"
    echo ""
    read -p "Отформатировать диски в ext4? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Форматирование диска 1
        if $DISK1_FOUND; then
            log_info "Форматируем $DISK1 ..."
            mkfs.ext4 -F -L "NAS-Disk-1" "$DISK1"
            log_success "✓ $DISK1 отформатирован"
        fi
        
        # Форматирование диска 2
        if $DISK2_FOUND; then
            log_info "Форматируем $DISK2 ..."
            mkfs.ext4 -F -L "NAS-Disk-2" "$DISK2"
            log_success "✓ $DISK2 отформатирован"
        fi
    else
        log_info "Форматирование пропущено. Предполагаем, что диски уже готовы."
    fi
    
    # Создаём точки монтирования
    mkdir -p "$MOUNT1" "$MOUNT2" "$DATA_MOUNT"
    
    # Получаем UUID дисков
    UUID1=$(blkid -s UUID -o value "$DISK1" 2>/dev/null || echo "")
    UUID2=$(blkid -s UUID -o value "$DISK2" 2>/dev/null || echo "")
    
    # Настраиваем /etc/fstab
    log_info "Настраиваем авто-монтирование в /etc/fstab"
    
    # Резервная копия fstab
    cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d%H%M)
    
    # Добавляем монтирование физических дисков (если не добавлено)
    if $DISK1_FOUND && [ -n "$UUID1" ] && ! grep -q "$UUID1" /etc/fstab; then
        echo "" >> /etc/fstab
        echo "# mbcloud NAS - Disk 1" >> /etc/fstab
        echo "UUID=$UUID1  $MOUNT1  ext4  defaults,noatime,nofail  0  2" >> /etc/fstab
        log_success "✓ Disk 1 добавлен в fstab"
    fi
    
    if $DISK2_FOUND && [ -n "$UUID2" ] && ! grep -q "$UUID2" /etc/fstab; then
        echo "" >> /etc/fstab
        echo "# mbcloud NAS - Disk 2" >> /etc/fstab
        echo "UUID=$UUID2  $MOUNT2  ext4  defaults,noatime,nofail  0  2" >> /etc/fstab
        log_success "✓ Disk 2 добавлен в fstab"
    fi
    
    # Добавляем MergerFS (если не добавлено)
    if ! grep -q "fuse.mergerfs" /etc/fstab; then
        echo "" >> /etc/fstab
        echo "# mbcloud NAS - MergerFS объединение" >> /etc/fstab
        echo "$MOUNT1:$MOUNT2  $DATA_MOUNT  fuse.mergerfs  defaults,allow_other,use_ino,category.create=epff  0  0" >> /etc/fstab
        log_success "✓ MergerFS добавлен в fstab"
    fi
    
    # Монтируем сейчас (без перезагрузки)
    log_info "Монтируем диски..."
    mount -a 2>/dev/null || log_warn "Некоторые точки монтирования не активированы (требуется перезагрузка)"
    
    # Создаём папки для приложений
    mkdir -p "$DATA_MOUNT/photos" "$DATA_MOUNT/import" "$DATA_MOUNT/immich-postgres" "$DATA_MOUNT/immich-redis"
    
    # Права доступа
    chown -R "${SUDO_USER:-mibitok}:${SUDO_USER:-mibitok}" "$DATA_MOUNT"
    
    log_success "Хранилище настроено: $DATA_MOUNT"
    df -h "$DATA_MOUNT" 2>/dev/null | tail -1 | awk '{print "  Доступно: " $4 " из " $2}'
}

# ============================================================================
# 📦 УСТАНОВКА ПАКЕТОВ И ЗАВИСИМОСТЕЙ
# ============================================================================
install_packages() {
    header "Установка пакетов"
    
    log_info "Обновляем систему..."
    apt update -qq && apt upgrade -y -qq
    
    log_info "Устанавливаем базовые утилиты..."
    apt install -y -qq \
        git curl wget htop tmux \
        python3-pip python3-venv python3-numpy \
        mergerfs smartmontools \
        samba samba-common-bin \
        i2c-tools read-edid \
        fonts-dejavu-core
    
    log_success "✓ Базовые пакеты установлены"
    
    # Устанавливаем Python-зависимости для дисплея
    log_info "Устанавливаем Python-библиотеки..."
    pip3 install -q --break-system-packages \
        psutil>=5.9.0 \
        gpiozero>=2.0 \
        Pillow>=9.0.0 2>/dev/null || log_warn "Некоторые Python-пакеты могли не установиться"
    
    log_success "✓ Python-зависимости установлены"
}

# ============================================================================
# 🐳 УСТАНОВКА DOCKER
# ============================================================================
install_docker() {
    header "Установка Docker"
    
    if command -v docker &>/dev/null; then
        log_info "Docker уже установлен"
    else
        log_info "Устанавливаем Docker..."
        curl -fsSL https://get.docker.com | sh
        log_success "✓ Docker установлен"
    fi
    
    # Добавляем пользователя в группу docker
    local user="${SUDO_USER:-mibitok}"
    if ! groups "$user" | grep -q docker; then
        usermod -aG docker "$user"
        log_info "✓ Пользователь $user добавлен в группу docker"
        log_warn "Для применения изменений группы требуется перезагрузка или: newgrp docker"
    fi
}

# ============================================================================
# 📥 КЛОНИРОВАНИЕ РЕПОЗИТОРИЯ И НАСТРОЙКА СЕРВИСОВ
# ============================================================================
setup_repository() {
    header "Клонирование репозитория"
    
    local user="${SUDO_USER:-mibitok}"
    local home="/home/$user"
    
    if [ -d "$REPO_PATH/.git" ]; then
        log_info "Репозиторий уже клонирован. Обновляем..."
        cd "$REPO_PATH"
        git pull -q
    else
        log_info "Клонируем репозиторий..."
        # Переключаемся на пользователя для правильных прав git
        su - "$user" -c "git clone $REPO_PATH" 2>/dev/null || \
        git clone "$REPO_URL" "$REPO_PATH"
    fi
    
    # Делаем скрипты исполняемыми
    chmod +x "$REPO_PATH/scripts/"*.sh 2>/dev/null || true
    
    log_success "✓ Репозиторий готов: $REPO_PATH"
}

# ============================================================================
# 🖥️ НАСТРОЙКА СЕРВИСА ДИСПЛЕЯ
# ============================================================================
setup_display_service() {
    header "Настройка сервиса дисплея"
    
    local user="${SUDO_USER:-mibitok}"
    local service_file="/etc/systemd/system/mbcloud-display.service"
    
    # Создаём systemd service
    cat > "$service_file" << 'EOF'
[Unit]
Description=mbcloud NAS LCD Display Service
After=network.target multi-user.target

[Service]
Type=simple
User=mbcloud-user
WorkingDirectory=/home/mbcloud-user/mbcloud-system/display
ExecStart=/usr/bin/python3 /home/mbcloud-user/mbcloud-system/display/main.py
Restart=on-failure
RestartSec=5s
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
EOF

    # Заменяем заглушки на реального пользователя
    sed -i "s/mbcloud-user/$user/g" "$service_file"
    
    # Перезагружаем systemd и включаем сервис
    systemctl daemon-reload
    systemctl enable mbcloud-display.service
    
    log_success "✓ Сервис дисплея настроен (не запущен)"
    log_info "Запустите: sudo systemctl start mbcloud-display.service"
}

# ============================================================================
# 🌐 НАСТРОЙКА SAMBA (СЕТЕВОЙ ДОСТУП)
# ============================================================================
setup_samba() {
    header "Настройка Samba"
    
    local user="${SUDO_USER:-mibitok}"
    
    # Резервная копия конфига
    cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d%H%M)
    
    # Добавляем нашу шару, если нет
    if ! grep -q "^\[mbcloud\]" /etc/samba/smb.conf; then
        cat >> /etc/samba/smb.conf << EOF

# mbcloud NAS share
[mbcloud]
   path = $DATA_MOUNT
   browseable = yes
   read only = no
   guest ok = no
   create mask = 0644
   directory mask = 0755
   force user = $user
EOF
        log_success "✓ Samba share [mbcloud] добавлен"
    fi
    
    # Создаём пароль Samba для пользователя (только если не существует)
    if ! smbpasswd -n "$user" &>/dev/null; then
        log_info "Настройте пароль Samba для пользователя $user:"
        log_info "  sudo smbpasswd -a $user"
    fi
    
    # Перезапускаем Samba
    systemctl restart smbd nmbd 2>/dev/null || true
    
    log_success "✓ Samba настроен"
    log_info "Доступ: \\\\$(hostname -I | awk '{print $1}')\\mbcloud"
}

# ============================================================================
# 🎉 ФИНАЛИЗАЦИЯ
# ============================================================================
finalize() {
    header "Завершение настройки"
    
    echo ""
    log_success "═══════════════════════════════════════"
    log_success "  mbcloud NAS готов к использованию!  "
    log_success "═══════════════════════════════════════"
    echo ""
    
    echo -e "${GREEN}Следующие шаги:${NC}"
    echo "  1. Перезагрузите систему:  sudo reboot"
    echo "  2. После перезагрузки:"
    echo "     • Запустите дисплей:    sudo systemctl start mbcloud-display.service"
    echo "     • Запустите Immich:     cd ~/mbcloud-system/docker && docker compose up -d"
    echo "  3. Настройте пароль Samba: sudo smbpasswd -a ${SUDO_USER:-mibitok}"
    echo "  4. Подключите iPhone к:    http://<IP-адрес>:2283"
    echo ""
    
    echo -e "${YELLOW}Полезные команды:${NC}"
    echo "  • Статус дисплея:  sudo systemctl status mbcloud-display.service"
    echo "  • Логи дисплея:    journalctl -u mbcloud-display.service -f"
    echo "  • Статус Docker:   docker compose -f ~/mbcloud-system/docker/docker-compose.yml ps"
    echo "  • Место на диске:  df -h /DATA"
    echo ""
    
    # Предложение перезагрузки
    read -p "Перезагрузить систему сейчас? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Перезагрузка..."
        reboot
    else
        log_warn "Не забудьте перезагрузить систему для применения всех изменений!"
    fi
}

# ============================================================================
# 🚀 ГЛАВНАЯ ФУНКЦИЯ
# ============================================================================
main() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  mbcloud NAS Auto-Setup Script     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════╝${NC}"
    echo ""
    
    check_prerequisites
    configure_display      # 🔥 ГЛАВНОЕ: настройка config.txt
    install_packages
    install_docker
    configure_storage      # Диски + MergerFS
    setup_repository
    setup_display_service
    setup_samba
    finalize
}

# Запуск
main "$@"
