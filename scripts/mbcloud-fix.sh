#!/bin/bash
#===============================================================================
# mbcloud NAS - Диагностика + Авто-исправление + Установка компонентов
# Использование: ./mbcloud-fix.sh [--auto] [--verbose]
# --auto   : автоматическое исправление без запросов
# --verbose: подробный вывод отладки
#===============================================================================

set -u  # Ошибка при необъявленных переменных

# 🎨 Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ⚙️ Конфигурация
REPO_PATH="${HOME}/mbcloud-system"
CONFIG_FILE="/boot/firmware/config.txt"
DISPLAY_SERVICE="mbcloud-display.service"
DATA_MOUNT="/DATA"
USER="${SUDO_USER:-$(whoami)}"
AUTO_MODE=false
VERBOSE=false

# 📊 Счётчики
declare -A ISSUES
ISSUES[critical]=0
ISSUES[warning]=0
ISSUES[fixed]=0
ISSUES[skipped]=0

# ============================================================================
# 📢 ФУНКЦИИ ВЫВОДА
# ============================================================================
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }
log_fix() { echo -e "${CYAN}[FIX]${NC} $1"; }

header() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  mbcloud FIX & DIAGNOSTIC v1.0     ║${NC}"
    echo -e "${GREEN}${BOD}╚════════════════════════════════════╝${NC}"
    echo "  Время: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Пользователь: $USER $([ $EUID -eq 0 ] && echo '(root)' || echo '')"
    echo "  Режим: $([ "$AUTO_MODE" = true ] && echo "🤖 Auto" || echo "👤 Interactive")"
    echo ""
}

ask() {
    if [ "$AUTO_MODE" = true ]; then
        return 0  # Авто-режим: всегда "да"
    fi
    read -p "$1 [y/N]: " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# ============================================================================
# 🔧 ФУНКЦИИ ИСПРАВЛЕНИЯ
# ============================================================================

# Установка пакета с обработкой ошибок
install_package() {
    local pkg=$1
    local desc=${2:-$pkg}
    
    if dpkg -l | grep -q "^ii  $pkg "; then
        log_ok "$desc уже установлен"
        return 0
    fi
    
    log "Устанавливаем $desc..."
    if apt install -y -qq "$pkg" 2>/dev/null; then
        log_ok "$desc установлен"
        ((ISSUES[fixed]++))
        return 0
    else
        log_err "Не удалось установить $desc"
        ((ISSUES[critical]++))
        return 1
    fi
}

# Установка Python-пакета
install_python_package() {
    local pkg=$1
    local import_name=${2:-$pkg}
    
    if python3 -c "import $import_name" 2>/dev/null; then
        log_ok "Python пакет $pkg уже установлен"
        return 0
    fi
    
    log "Устанавливаем Python пакет $pkg..."
    if pip3 install -q --break-system-packages "$pkg" 2>/dev/null; then
        log_ok "Python пакет $pkg установлен"
        ((ISSUES[fixed]++))
        return 0
    else
        log_err "Не удалось установить $pkg"
        ((ISSUES[critical]++))
        return 1
    fi
}

# Добавление строки в конфиг (если нет)
add_to_config() {
    local file=$1
    local line=$2
    local desc=$3
    
    if grep -qF "$line" "$file" 2>/dev/null; then
        log_ok "$desc уже в $file"
        return 0
    fi
    
    log "Добавляем в $file: $line"
    echo "$line" >> "$file"
    log_ok "$desc добавлен"
    ((ISSUES[fixed]++))
    return 0
}

# Создание директории с правами
ensure_dir() {
    local dir=$1
    local user=${2:-$USER}
    
    if [ -d "$dir" ]; then
        log_ok "Директория существует: $dir"
        return 0
    fi
    
    log "Создаём директорию: $dir"
    mkdir -p "$dir"
    chown "$user:$user" "$dir" 2>/dev/null || true
    log_ok "Директория создана: $dir"
    ((ISSUES[fixed]++))
}

# Перезапуск сервиса
restart_service() {
    local service=$1
    
    if ! systemctl list-unit-files | grep -q "$service"; then
        log_warn "Сервис $service не зарегистрирован"
        ((ISSUES[warning]++))
        return 1
    fi
    
    log "Перезапускаем $service..."
    if systemctl restart "$service" 2>/dev/null; then
        sleep 2
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            log_ok "$service перезапущен и активен"
            ((ISSUES[fixed]++))
            return 0
        fi
    fi
    
    log_err "Не удалось перезапустить $service"
    ((ISSUES[critical]++))
    return 1
}

# ============================================================================
# 🔍 ПРОВЕРКИ С АВТО-ИСПРАВЛЕНИЕМ
# ============================================================================

check_and_fix_system() {
    echo -e "\n${CYAN}${BOLD}▶ Система и обновления${NC}"
    
    # Обновление пакетов
    if ask "Обновить пакеты системы?"; then
        log "Обновляем индексы..."
        apt update -qq
        if ask "Установить доступные обновления?"; then
            apt upgrade -y -qq && log_ok "Система обновлена" || log_warn "Обновление с предупреждениями"
        fi
    else
        log "Пропущено обновление системы"
    fi
    
    # Проверка архитектуры
    if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
        log_warn "Не обнаружен Raspberry Pi"
        ((ISSUES[warning]++))
    fi
}

check_and_fix_interfaces() {
    echo -e "\n${CYAN}${BOLD}▶ Аппаратные интерфейсы${NC}"
    
    # SPI для дисплея
    if [ ! -c /dev/spidev0.0 ]; then
        log_err "SPI интерфейс не активен"
        ((ISSUES[critical]++))
        if ask "Включить SPI в $CONFIG_FILE?"; then
            add_to_config "$CONFIG_FILE" "dtparam=spi=on" "SPI интерфейс"
            log_warn "Требуется перезагрузка для применения!"
        fi
    else
        log_ok "SPI активен"
    fi
    
    # I2C для RTC
    if [ ! -c /dev/i2c-1 ]; then
        log_err "I2C интерфейс не активен"
        ((ISSUES[critical]++))
        if ask "Включить I2C в $CONFIG_FILE?"; then
            add_to_config "$CONFIG_FILE" "dtparam=i2c_arm=on" "I2C интерфейс"
            log_warn "Требуется перезагрузка для применения!"
        fi
    else
        log_ok "I2C активен"
        
        # Проверка RTC
        if ! i2cdetect -y 1 2>/dev/null | grep -qE "51|68"; then
            log_warn "RTC не обнаружен на шине"
            ((ISSUES[warning]++))
            if ask "Добавить overlay RTC в $CONFIG_FILE?"; then
                add_to_config "$CONFIG_FILE" "dtoverlay=i2c-rtc,pcf85063a" "RTC PCF85063a"
                log_warn "Требуется перезагрузка!"
            fi
        else
            log_ok "RTC обнаружен"
        fi
    fi
    
    # GPIO права
    if ! groups "$USER" | grep -q gpio; then
        log_warn "Пользователь не в группе gpio"
        ((ISSUES[warning]++))
        if ask "Добавить пользователя в группу gpio?"; then
            usermod -aG gpio "$USER"
            log_warn "Требуется перезагрузка или: newgrp gpio"
            ((ISSUES[fixed]++))
        fi
    else
        log_ok "GPIO права настроены"
    fi
}

check_and_fix_config_files() {
    echo -e "\n${CYAN}${BOLD}▶ Конфигурационные файлы${NC}"
    
    # Проверка config.txt
    if [ ! -f "$CONFIG_FILE" ]; then
        log_err "$CONFIG_FILE не найден"
        ((ISSUES[critical]++))
        return 1
    fi
    
    # fstab проверка
    if [ -f /etc/fstab ]; then
        if ! grep -q "fuse.mergerfs" /etc/fstab; then
            log_warn "MergerFS не настроен в fstab"
            ((ISSUES[warning]++))
            if ask "Настроить MergerFS в fstab?"; then
                cat >> /etc/fstab << 'EOF'

# mbcloud NAS - MergerFS
/mnt/disk1:/mnt/disk2  /DATA  fuse.mergerfs  defaults,allow_other,use_ino,category.create=epff  0  0
EOF
                log_ok "MergerFS добавлен в fstab"
                ((ISSUES[fixed]++))
            fi
        else
            log_ok "MergerFS в fstab"
        fi
    fi
    
    # Сервис дисплея
    if ! systemctl list-unit-files | grep -q "$DISPLAY_SERVICE"; then
        log_warn "Сервис $DISPLAY_SERVICE не зарегистрирован"
        ((ISSUES[warning]++))
        if ask "Создать сервис дисплея?"; then
            setup_display_service
        fi
    elif ! systemctl is-active --quiet "$DISPLAY_SERVICE" 2>/dev/null; then
        log_warn "Сервис $DISPLAY_SERVICE не активен"
        ((ISSUES[warning]++))
        if ask "Перезапустить сервис дисплея?"; then
            restart_service "$DISPLAY_SERVICE"
        fi
    else
        log_ok "Сервис дисплея активен"
    fi
}

check_and_fix_docker() {
    echo -e "\n${CYAN}${BOLD}▶ Docker и контейнеры${NC}"
    
    # Docker установлен
    if ! command -v docker &>/dev/null; then
        log_err "Docker не установлен"
        ((ISSUES[critical]++))
        if ask "Установить Docker?"; then
            curl -fsSL https://get.docker.com | sh && log_ok "Docker установлен" || log_err "Ошибка установки Docker"
        fi
    else
        log_ok "Docker установлен: $(docker --version | cut -d' ' -f3)"
    fi
    
    # Docker сервис
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        log_warn "Docker сервис не активен"
        if ask "Запустить Docker сервис?"; then
            systemctl start docker && systemctl enable docker && log_ok "Docker запущен" || log_err "Ошибка запуска Docker"
        fi
    fi
    
    # Пользователь в группе docker
    if ! groups "$USER" | grep -q docker; then
        log_warn "Пользователь не в группе docker"
        if ask "Добавить пользователя в группу docker?"; then
            usermod -aG docker "$USER"
            log_warn "Примените: newgrp docker или перезайдите"
            ((ISSUES[fixed]++))
        fi
    fi
    
    # Docker Compose
    if ! docker compose version &>/dev/null 2>&1 && ! command -v docker-compose &>/dev/null; then
        log_warn "Docker Compose не найден"
        ((ISSUES[warning]++))
        if ask "Установить Docker Compose плагин?"; then
            apt install -y -qq docker-compose-plugin && log_ok "Docker Compose установлен" || log_warn "Не удалось установить"
        fi
    else
        log_ok "Docker Compose доступен"
    fi
}

check_and_fix_storage() {
    echo -e "\n${CYAN}${BOLD}▶ Хранилище и диски${NC}"
    
    # Проверка точки /DATA
    if ! mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        log_warn "Точка $DATA_MOUNT не смонтирована"
        ((ISSUES[warning]++))
        if ask "Смонтировать /DATA сейчас?"; then
            mkdir -p "$DATA_MOUNT"
            mount -a 2>/dev/null && log_ok "Диски смонтированы" || log_err "Ошибка монтирования"
        fi
    else
        log_ok "Хранилище $DATA_MOUNT активно"
        df -h "$DATA_MOUNT" | tail -1 | awk '{print "  ℹ Доступно: " $4 " из " $2 " (" $5 ")"}'
    fi
    
    # Папки для приложений
    for folder in photos import immich-postgres immich-redis backups; do
        ensure_dir "$DATA_MOUNT/$folder" "$USER"
    done
    
    # Права доступа
    if [ -d "$DATA_MOUNT" ]; then
        chown -R "$USER:$USER" "$DATA_MOUNT" 2>/dev/null || true
        log_ok "Права на $DATA_MOUNT настроены"
    fi
}

check_and_fix_network() {
    echo -e "\n${CYAN}${BOLD}▶ Сеть и сервисы${NC}"
    
    # Samba
    if command -v smbd &>/dev/null; then
        if ! grep -q "^\[mbcloud\]" /etc/samba/smb.conf 2>/dev/null; then
            log_warn "Samba share [mbcloud] не настроен"
            ((ISSUES[warning]++))
            if ask "Настроить Samba share?"; then
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
                systemctl restart smbd 2>/dev/null
                log_ok "Samba share настроен"
                ((ISSUES[fixed]++))
            fi
        else
            log_ok "Samba share настроен"
        fi
    else
        log_warn "Samba не установлен"
        ((ISSUES[warning]++))
        if ask "Установить Samba?"; then
            install_package "samba" "Samba сервер"
        fi
    fi
}

check_and_fix_python() {
    echo -e "\n${CYAN}${BOLD}▶ Python и зависимости${NC}"
    
    # Базовые пакеты
    for pkg in psutil gpiozero; do
        if ! python3 -c "import $pkg" 2>/dev/null; then
            log_warn "Python пакет $pkg не установлен"
            ((ISSUES[warning]++))
            if ask "Установить $pkg?"; then
                install_python_package "$pkg"
            fi
        else
            log_ok "Python пакет: $pkg"
        fi
    done
    
    # Pillow (импортируется как PIL)
    if ! python3 -c "import PIL" 2>/dev/null; then
        log_warn "Python пакет Pillow не установлен"
        ((ISSUES[warning]++))
        if ask "Установить Pillow?"; then
            install_python_package "Pillow" "PIL"
        fi
    else
        log_ok "Python пакет: Pillow (PIL)"
    fi
    
    # Шрифт Baveuse
    font_path="$REPO_PATH/display/fonts/Baveuse.ttf"
    if [ ! -f "$font_path" ] || [ ! -s "$font_path" ]; then
        log_warn "Шрифт Baveuse не найден или пуст"
        ((ISSUES[warning]++))
        if ask "Скачать шрифт Baveuse?"; then
            mkdir -p "$(dirname "$font_path")"
            wget -q -O "$font_path" "https://github.com/mibitok/mbcloud-system/raw/main/fonts/Baveuse.ttf" 2>/dev/null || \
            log_err "Не удалось скачать шрифт"
            [ -s "$font_path" ] && log_ok "Шрифт скачан" || ((ISSUES[critical]++))
        fi
    else
        log_ok "Шрифт Baveuse: $(stat -c%s "$font_path") байт"
    fi
}

check_and_fix_repository() {
    echo -e "\n${CYAN}${BOLD}▶ Репозиторий и обновления${NC}"
    
    if [ ! -d "$REPO_PATH/.git" ]; then
        log_warn "Git репозиторий не найден в $REPO_PATH"
        ((ISSUES[warning]++))
        if ask "Клонировать репозиторий?"; then
            git clone https://github.com/mibitok/mbcloud-system.git "$REPO_PATH" && \
            log_ok "Репозиторий клонирован" || log_err "Ошибка клонирования"
        fi
    else
        cd "$REPO_PATH"
        
        # Проверка незакоммиченных изменений
        if git status --porcelain 2>/dev/null | grep -q .; then
            log_warn "Есть незакоммиченные изменения"
            ((ISSUES[warning]++))
            if ask "Закоммить изменения?"; then
                git add -A
                git commit -m "Auto-commit: $(date '+%Y-%m-%d %H:%M')"
                log_ok "Изменения закоммичены"
            fi
        else
            log_ok "Рабочее дерево чистое"
        fi
        
        # Проверка обновлений
        if git fetch --dry-run 2>/dev/null | grep -q .; then
            log_warn "Есть обновления в удалённом репозитории"
            ((ISSUES[warning]++))
            if ask "Обновить репозиторий?"; then
                git pull && log_ok "Репозиторий обновлён" || log_warn "Ошибка обновления"
            fi
        else
            log_ok "Репозиторий актуален"
        fi
    fi
}

# ============================================================================
# 🖥️ СОЗДАНИЕ СЕРВИСА ДИСПЛЕЯ
# ============================================================================
setup_display_service() {
    local service_file="/etc/systemd/system/$DISPLAY_SERVICE"
    
    cat > "$service_file" << EOF
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
    systemctl enable "$DISPLAY_SERVICE"
    log_ok "Сервис $DISPLAY_SERVICE создан и включён"
}

# ============================================================================
# 📋 ФИНАЛЬНЫЙ ОТЧЁТ
# ============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  СВОДНЫЙ ОТЧЁТ ПО ИСПРАВЛЕНИЯМ${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${BOLD}Результаты:${NC}"
    echo -e "  ${GREEN}✓ Исправлено:${NC}  ${ISSUES[fixed]}"
    echo -e "  ${RED}✗ Критические:${NC} ${ISSUES[critical]}"
    echo -e "  ${YELLOW}⚠ Предупреждения:${NC} ${ISSUES[warning]}"
    echo -e "  ${BLUE}○ Пропущено:${NC} ${ISSUES[skipped]}"
    echo ""
    
    if [ ${ISSUES[critical]} -eq 0 ]; then
        echo -e "${GREEN}${BOLD}🎉 СИСТЕМА В ПОРЯДКЕ!${NC}"
        echo "Все критические компоненты работают или исправлены."
    else
        echo -e "${RED}${BOLD}⚠ ТРЕБУЕТСЯ ВНИМАНИЕ${NC}"
        echo "Исправьте ${ISSUES[critical]} критических проблем вручную."
    fi
    
    echo ""
    echo -e "${BOLD}Полезные команды:${NC}"
    echo "  • Логи дисплея:     journalctl -u $DISPLAY_SERVICE -f"
    echo "  • Статус Docker:    docker compose -f $REPO_PATH/docker/docker-compose.yml ps"
    echo "  • Место на диске:   df -h $DATA_MOUNT"
    echo "  • Температура:      vcgencmd measure_temp"
    echo "  • Перезагрузка:     sudo reboot"
    echo ""
    
    # Предложение перезагрузки если меняли config.txt
    if grep -q "backup.$(date +%Y)" "${CONFIG_FILE}.backup."* 2>/dev/null; then
        echo -e "${YELLOW}⚠  Вы изменили $CONFIG_FILE${NC}"
        echo "Для применения изменений требуется перезагрузка."
        if ask "Перезагрузить систему сейчас?"; then
            log "Перезагрузка..."
            reboot
        fi
    fi
}

# ============================================================================
# 🚀 ГЛАВНАЯ ФУНКЦИЯ
# ============================================================================
main() {
    # Парсинг аргументов
    while [[ $# -gt 0 ]]; do
        case $1 in
            --auto|-a) AUTO_MODE=true; shift ;;
            --verbose|-v) VERBOSE=true; shift ;;
            --help|-h)
                echo "Использование: $0 [опции]"
                echo "Опции:"
                echo "  --auto, -a    Автоматическое исправление без запросов"
                echo "  --verbose, -v Подробный вывод"
                echo "  --help, -h    Показать эту справку"
                exit 0
                ;;
            *) shift ;;
        esac
    done
    
    # Проверка прав
    if [ $EUID -ne 0 ] && [ "$AUTO_MODE" = false ]; then
        log_warn "Для полной функциональности запустите с sudo"
        if ! ask "Продолжить без прав root?"; then
            echo "Запуск с sudo: sudo $0 $*"
            exit 1
        fi
    fi
    
    header
    
    # Запуск проверок с исправлениями
    check_and_fix_system
    check_and_fix_interfaces
    check_and_fix_config_files
    check_and_fix_docker
    check_and_fix_storage
    check_and_fix_network
    check_and_fix_python
    check_and_fix_repository
    
    # Финальный отчёт
    print_summary
    
    # Код выхода
    [ ${ISSUES[critical]} -gt 0 ] && exit 1 || exit 0
}

# Запуск
main "$@"
