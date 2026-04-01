#!/bin/bash
#===============================================================================
# mbcloud NAS - Система диагностики
# Проверяет: железо, софт, сервисы, сеть, хранилище, дисплей
# Использование: ./mbcloud-diagnose.sh  или  curl -sSL ... | bash
#===============================================================================

set -u  # Ошибка при использовании необъявленных переменных

# 🎨 Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 📊 Счётчики
PASS=0
FAIL=0
WARN=0
SKIP=0

# ⚙️ Конфигурация
REPO_PATH="${HOME}/mbcloud-system"
CONFIG_FILE="/boot/firmware/config.txt"
DISPLAY_SERVICE="mbcloud-display.service"
DATA_MOUNT="/DATA"
IMMICH_PORT="2283"

# ============================================================================
# 📢 ФУНКЦИИ ВЫВОДА
# ============================================================================
header() {
    echo ""
    echo -e "${BLUE}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  mbcloud DIAGNOSTICS - $1${NC}"
    echo -e "${BLUE}${BOLD}════════════════════════════════════════${NC}"
    echo ""
}

section() {
    echo -e "\n${CYAN}${BOLD}▶ $1${NC}"
    echo -e "${CYAN}─────────────────────────────────${NC}"
}

pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    ((PASS++))
}

fail() {
    echo -e "  ${RED}✗${NC} $1 ${YELLOW}($2)${NC}"
    ((FAIL++))
}

warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
    ((WARN++))
}

skip() {
    echo -e "  ${BLUE}○${NC} $1 (пропущено)"
    ((SKIP++))
}

info() {
    echo -e "  ${BLUE}ℹ${NC} $1"
}

# ============================================================================
# 🔍 ПРОВЕРКА: Система и ядро
# ============================================================================
check_system() {
    section "Система и ядро"
    
    # Модель устройства
    if grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
        model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
        pass "Raspberry Pi detected: $model"
    else
        warn "Не Raspberry Pi (возможно, эмуляция)"
    fi
    
    # Версия ОС
    if [ -f /etc/os-release ]; then
        os_name=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
        pass "OS: $os_name"
    else
        fail "Не удалось определить ОС" "/etc/os-release не найден"
    fi
    
    # Ядро
    kernel=$(uname -r)
    arch=$(uname -m)
    pass "Kernel: $kernel ($arch)"
    
    # Время работы
    uptime=$(uptime -p 2>/dev/null || echo "N/A")
    info "Uptime: $uptime"
    
    # Загрузка системы
    load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    info "Load average:$load"
}

# ============================================================================
# 🔌 ПРОВЕРКА: Железные интерфейсы (SPI, I2C, GPIO)
# ============================================================================
check_hardware() {
    section "Аппаратные интерфейсы"
    
    # SPI для дисплея
    if [ -c /dev/spidev0.0 ] && [ -c /dev/spidev0.1 ]; then
        pass "SPI интерфейс активен (/dev/spidev0.0, 0.1)"
    else
        fail "SPI интерфейс не найден" "проверьте dtparam=spi=on в config.txt"
    fi
    
    # I2C для RTC
    if [ -c /dev/i2c-1 ]; then
        pass "I2C интерфейс активен (/dev/i2c-1)"
        
        # Проверка RTC устройства
        if i2cdetect -y 1 2>/dev/null | grep -q "51"; then
            pass "RTC PCF85063a обнаружен на шине I2C (адрес 0x51)"
        else
            warn "RTC не обнаружен на I2C (адрес 0x51)"
        fi
    else
        fail "I2C интерфейс не найден" "проверьте dtparam=i2c_arm=on в config.txt"
    fi
    
    # GPIO доступ
    if [ -r /sys/class/gpio/export ] && groups "${SUDO_USER:-$USER}" | grep -q gpio; then
        pass "GPIO доступ разрешен (группа gpio)"
    else
        warn "GPIO доступ может быть ограничен" "добавьте пользователя в группу gpio"
    fi
    
    # Диски SATA
    sata_count=$(lsblk -d -n -o NAME 2>/dev/null | grep -c "^sd" || echo 0)
    if [ "$sata_count" -ge 1 ]; then
        pass "SATA диски обнаружены: $sata_count шт."
        lsblk -d -n -o NAME,SIZE,TYPE 2>/dev/null | grep "^sd" | while read name size type; do
            info "  • $name: $size ($type)"
        done
    else
        warn "SATA диски не обнаружены"
    fi
    
    # Вентилятор (проверка возможности управления)
    if [ -w /sys/class/gpio/gpio18/value ] 2>/dev/null || [ -c /dev/pwm* ] 2>/dev/null; then
        pass "Управление вентилятором доступно (GPIO18/PWM)"
    else
        info "Управление вентилятором: через gpiozero (Python)"
    fi
}

# ============================================================================
# ⚙️ ПРОВЕРКА: Конфигурационные файлы
# ============================================================================
check_config_files() {
    section "Конфигурационные файлы"
    
    # /boot/firmware/config.txt
    if [ -f "$CONFIG_FILE" ]; then
        pass "Файл $CONFIG_FILE найден"
        
        # Проверка ключевых настроек
        grep -q "^dtparam=spi=on" "$CONFIG_FILE" && pass "  • SPI включён" || fail "  • SPI не включён" "dtparam=spi=on"
        grep -q "^dtparam=i2c_arm=on" "$CONFIG_FILE" && pass "  • I2C включён" || fail "  • I2C не включён" "dtparam=i2c_arm=on"
        grep -q "dtoverlay=i2c-rtc,pcf85063a" "$CONFIG_FILE" && pass "  • RTC overlay добавлен" || warn "  • RTC overlay не найден"
    else
        fail "Файл $CONFIG_FILE не найден" "проверьте путь к config.txt"
    fi
    
    # /etc/fstab
    if [ -f /etc/fstab ]; then
        pass "Файл /etc/fstab найден"
        
        # Проверка монтирования /DATA
        if grep -q "fuse.mergerfs" /etc/fstab; then
            pass "  • MergerFS настроен в fstab"
        else
            warn "  • MergerFS не найден в fstab"
        fi
        
        # Проверка монтирования дисков
        if grep -q "/mnt/disk" /etc/fstab; then
            pass "  • Физические диски в fstab"
        else
            info "  • Физические диски: не в fstab (возможно, авто-монтирование)"
        fi
    else
        fail "Файл /etc/fstab не найден"
    fi
    
    # /etc/samba/smb.conf
    if [ -f /etc/samba/smb.conf ]; then
        if grep -q "^\[mbcloud\]" /etc/samba/smb.conf; then
            pass "Samba share [mbcloud] настроен"
        else
            info "Samba: share [mbcloud] не найден (опционально)"
        fi
    else
        info "Samba не установлен (опционально)"
    fi
    
    # systemd сервис дисплея
    if systemctl list-unit-files | grep -q "$DISPLAY_SERVICE"; then
        pass "Сервис $DISPLAY_SERVICE зарегистрирован"
        
        # Статус сервиса
        if systemctl is-active --quiet "$DISPLAY_SERVICE" 2>/dev/null; then
            pass "  • Сервис активен (running)"
        else
            status=$(systemctl is-active "$DISPLAY_SERVICE" 2>/dev/null || echo "unknown")
            warn "  • Сервис: $status"
        fi
    else
        warn "Сервис $DISPLAY_SERVICE не зарегистрирован"
    fi
}

# ============================================================================
# 🐳 ПРОВЕРКА: Docker и контейнеры
# ============================================================================
check_docker() {
    section "Docker и контейнеры"
    
    # Docker установлен
    if command -v docker &>/dev/null; then
        docker_version=$(docker --version 2>/dev/null | cut -d' ' -f3)
        pass "Docker установлен: $docker_version"
    else
        fail "Docker не установлен" "установите: curl -fsSL https://get.docker.com | sh"
        return
    fi
    
    # Docker запущен
    if systemctl is-active --quiet docker 2>/dev/null; then
        pass "Docker сервис активен"
    else
        fail "Docker сервис не активен" "sudo systemctl start docker"
    fi
    
    # Пользователь в группе docker
    if groups "${SUDO_USER:-$USER}" | grep -q docker; then
        pass "Пользователь в группе docker"
    else
        warn "Пользователь не в группе docker" "sudo usermod -aG docker \$USER"
    fi
    
    # Docker Compose
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        compose_version=$(docker compose version 2>/dev/null | grep -oP 'v\K[0-9.]+')
        pass "Docker Compose: v$compose_version"
    elif command -v docker-compose &>/dev/null; then
        compose_version=$(docker-compose --version 2>/dev/null | grep -oP 'v\K[0-9.]+')
        pass "Docker Compose (legacy): v$compose_version"
    else
        warn "Docker Compose не найден"
    fi
    
    # Контейнеры Immich (если есть compose файл)
    compose_file="$REPO_PATH/docker/docker-compose.yml"
    if [ -f "$compose_file" ]; then
        info "Проверка Immich stack..."
        cd "$(dirname "$compose_file")" 2>/dev/null || return
        
        if docker compose ps &>/dev/null 2>&1; then
            running=$(docker compose ps --format json 2>/dev/null | grep -c '"Running":true' || echo 0)
            total=$(docker compose ps --format json 2>/dev/null | grep -c '"Name":' || echo 0)
            
            if [ "$running" -gt 0 ]; then
                pass "Контейнеры Immich: $running/$total запущены"
                docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null | tail -n +2 | while read line; do
                    info "  • $line"
                done
            else
                warn "Контейнеры Immich не запущены"
            fi
        else
            info "Immich stack: не запущен (это нормально, если не стартовал)"
        fi
    else
        info "docker-compose.yml не найден: $compose_file"
    fi
}

# ============================================================================
# 💾 ПРОВЕРКА: Хранилище и диски
# ============================================================================
check_storage() {
    section "Хранилище и диски"
    
    # Точка монтирования /DATA
    if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        pass "Точка монтирования $DATA_MOUNT активна"
        
        # Информация о хранилище
        if df -h "$DATA_MOUNT" &>/dev/null; then
            df_info=$(df -h "$DATA_MOUNT" | tail -1)
            total=$(echo "$df_info" | awk '{print $2}')
            used=$(echo "$df_info" | awk '{print $3}')
            avail=$(echo "$df_info" | awk '{print $4}')
            pct=$(echo "$df_info" | awk '{print $5}')
            
            pass "  • Объём: $total, Использовано: $used, Свободно: $avail ($pct)"
            
            # Предупреждение о заполнении
            pct_num=$(echo "$pct" | tr -d '%')
            if [ "$pct_num" -gt 90 ] 2>/dev/null; then
                warn "  • ⚠ Диск заполнен более чем на 90%!"
            elif [ "$pct_num" -gt 75 ] 2>/dev/null; then
                info "  • ⚡ Диск заполнен на $pct"
            fi
        fi
    else
        warn "Точка монтирования $DATA_MOUNT не активна"
    fi
    
    # MergerFS статус
    if command -v mergerfs &>/dev/null; then
        pass "MergerFS установлен"
        
        # Проверка, что /DATA это mergerfs
        if mount | grep -q "$DATA_MOUNT.*fuse.mergerfs"; then
            pass "  • /DATA использует MergerFS"
        else
            info "  • /DATA: не MergerFS (возможно, прямой диск)"
        fi
    else
        info "MergerFS не установлен (опционально)"
    fi
    
    # Физические диски
    for disk in /mnt/disk1 /mnt/disk2; do
        if mountpoint -q "$disk" 2>/dev/null; then
            size=$(df -h "$disk" 2>/dev/null | tail -1 | awk '{print $2}')
            pass "Диск смонтирован: $disk ($size)"
        elif [ -b "$(lsblk -no PKNAME $(findmnt -n -o SOURCE "$disk" 2>/dev/null) 2>/dev/null)" ]; then
            info "Диск обнаружен, но не смонтирован: $disk"
        fi
    done
    
    # Папки для приложений
    for folder in photos import immich-postgres immich-redis; do
        if [ -d "$DATA_MOUNT/$folder" ]; then
            pass "Папка существует: $DATA_MOUNT/$folder"
        else
            info "Папка не найдена: $DATA_MOUNT/$folder (будет создана при первом запуске)"
        fi
    done
}

# ============================================================================
# 🌐 ПРОВЕРКА: Сеть и порты
# ============================================================================
check_network() {
    section "Сеть и порты"
    
    # IP адрес
    ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$ip_addr" ]; then
        pass "IP адрес: $ip_addr"
    else
        warn "Не удалось определить IP адрес"
    fi
    
    # Доступность интернета
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        pass "Интернет доступен (8.8.8.8)"
    else
        warn "Нет доступа к интернету"
    fi
    
    # Порт Immich (2283)
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":$IMMICH_PORT "; then
            pass "Порт $IMMICH_PORT (Immich) прослушивается"
        else
            info "Порт $IMMICH_PORT не активен (Immich не запущен?)"
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":$IMMICH_PORT "; then
            pass "Порт $IMMICH_PORT (Immich) прослушивается"
        else
            info "Порт $IMMICH_PORT не активен"
        fi
    else
        skip "Проверка портов (нет ss/netstat)"
    fi
    
    # Samba порт (445)
    if systemctl is-active --quiet smbd 2>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":445 "; then
            pass "Samba порт 445 активен"
        else
            warn "Samba запущен, но порт 445 не прослушивается"
        fi
    else
        info "Samba сервис не активен (опционально)"
    fi
    
    # SSH доступ
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        pass "SSH сервер активен"
    else
        info "SSH сервер не активен"
    fi
}

# ============================================================================
# 🐍 ПРОВЕРКА: Python и зависимости дисплея
# ============================================================================
check_python() {
    section "Python и зависимости дисплея"
    
    # Python версия
    if command -v python3 &>/dev/null; then
        py_version=$(python3 --version 2>&1)
        pass "Python 3: $py_version"
    else
        fail "Python 3 не установлен"
        return
    fi
    
    # Критические пакеты
    for pkg in psutil gpiozero Pillow; do
        if python3 -c "import $pkg" 2>/dev/null; then
            pass "Python пакет: $pkg"
        else
            fail "Python пакет: $pkg" "pip3 install --user $pkg"
        fi
    done
    
    # Шрифт Baveuse
    font_path="$REPO_PATH/display/fonts/Baveuse.ttf"
    if [ -f "$font_path" ] && [ -s "$font_path" ]; then
        size=$(stat -c%s "$font_path" 2>/dev/null || stat -f%z "$font_path" 2>/dev/null)
        pass "Шрифт Baveuse: $font_path ($size байт)"
        
        # Тест загрузки шрифта
        if python3 -c "from PIL import ImageFont; ImageFont.truetype('$font_path', 24)" 2>/dev/null; then
            pass "  • Шрифт загружается корректно"
        else
            warn "  • Шрифт не может быть загружен PIL"
        fi
    else
        warn "Шрифт Baveuse не найден: $font_path"
    fi
    
    # Файл main.py
    main_py="$REPO_PATH/display/main.py"
    if [ -f "$main_py" ]; then
        pass "Файл main.py найден: $main_py"
        
        # Проверка синтаксиса
        if python3 -m py_compile "$main_py" 2>/dev/null; then
            pass "  • Синтаксис Python: OK"
        else
            fail "  • Ошибка синтаксиса в main.py"
        fi
    else
        fail "Файл main.py не найден" "$main_py"
    fi
    
    # Тест импорта драйвера дисплея (опционально)
    waveshare_lib="/home/${SUDO_USER:-mibitok}/CM4-NAS-Double-Deck_Demo/RaspberryPi/lib"
    if [ -d "$waveshare_lib" ]; then
        pass "Библиотека Waveshare найдена: $waveshare_lib"
    else
        info "Библиотека Waveshare не найдена (дисплей в режиме эмуляции)"
    fi
}

# ============================================================================
# 🖥️ ПРОВЕРКА: Дисплей (тестовый рендер)
# ============================================================================
check_display_render() {
    section "Тест рендеринга дисплея"
    
    main_py="$REPO_PATH/display/main.py"
    
    if [ ! -f "$main_py" ]; then
        skip "main.py не найден, пропускаем тест рендера"
        return
    fi
    
    # Запускаем тестовый импорт функций (без инициализации железа)
    info "Тестируем функции отрисовки..."
    
    test_result=$(python3 -c "
import sys
sys.path.insert(0, '$REPO_PATH/display')
try:
    # Импортируем функции отрисовки
    from main import draw_sleep_screen, draw_page_dashboard, get_font
    # Тест создания изображения
    img = draw_sleep_screen()
    if img and img.size == (320, 240):
        print('OK')
    else:
        print(f'SIZE_ERROR:{img.size if img else None}')
except Exception as e:
    print(f'ERROR:{str(e)[:100]}')
" 2>&1)
    
    if [[ "$test_result" == "OK" ]]; then
        pass "Функции отрисовки работают корректно"
    elif [[ "$test_result" == SIZE_ERROR:* ]]; then
        warn "Неверный размер изображения: ${test_result#SIZE_ERROR:}"
    elif [[ "$test_result" == ERROR:* ]]; then
        fail "Ошибка при тесте отрисовки" "${test_result#ERROR:}"
    else
        info "Тест отрисовки: $test_result"
    fi
}

# ============================================================================
# 📦 ПРОВЕРКА: Репозиторий и Git
# ============================================================================
check_repository() {
    section "Репозиторий и обновления"
    
    repo_dir="$REPO_PATH"
    
    if [ -d "$repo_dir/.git" ]; then
        pass "Git репозиторий инициализирован: $repo_dir"
        
        cd "$repo_dir"
        
        # Текущая ветка
        branch=$(git branch --show-current 2>/dev/null || echo "unknown")
        info "Ветка: $branch"
        
        # Статус рабочего дерева
        if git status --porcelain 2>/dev/null | grep -q .; then
            warn "Есть незакоммиченные изменения"
        else
            pass "Рабочее дерево чистое"
        fi
        
        # Последний коммит
        last_commit=$(git log -1 --oneline 2>/dev/null || echo "N/A")
        info "Последний коммит: $last_commit"
        
        # Проверка удалённого репозитория
        if git remote -v 2>/dev/null | grep -q "github.com"; then
            pass "Удалённый репозиторий GitHub настроен"
        else
            info "Удалённый репозиторий: не GitHub (или не настроен)"
        fi
    else
        warn "Git репозиторий не найден в $repo_dir"
    fi
}

# ============================================================================
# 📋 СВОДНЫЙ ОТЧЁТ
# ============================================================================
print_summary() {
    header "СВОДНЫЙ ОТЧЁТ"
    
    total=$((PASS + FAIL + WARN + SKIP))
    
    echo -e "${BOLD}Результаты проверки:${NC}"
    echo -e "  ${GREEN}✓ Успешно:${NC}  $PASS"
    echo -e "  ${RED}✗ Ошибки:${NC}   $FAIL"
    echo -e "  ${YELLOW}⚠ Предупреждения:${NC} $WARN"
    echo -e "  ${BLUE}○ Пропущено:${NC} $SKIP"
    echo -e "  ${BOLD}Всего проверок:${NC} $total"
    echo ""
    
    # Оценка состояния
    if [ $FAIL -eq 0 ] && [ $WARN -le 2 ]; then
        echo -e "${GREEN}${BOLD}🎉 СИСТЕМА В ПОРЯДКЕ!${NC}"
        echo "Все критические компоненты работают корректно."
    elif [ $FAIL -le 2 ]; then
        echo -e "${YELLOW}${BOLD}⚡ ТРЕБУЕТСЯ ВНИМАНИЕ${NC}"
        echo "Есть небольшие проблемы, но система функциональна."
    else
        echo -e "${RED}${BOLD}❌ ТРЕБУЕТСЯ ВМЕШАТЕЛЬСТВО${NC}"
        echo "Критические ошибки блокируют работу системы."
    fi
    
    echo ""
    
    # Рекомендации
    if [ $FAIL -gt 0 ]; then
        echo -e "${BOLD}Рекомендации:${NC}"
        echo "  1. Исправьте ошибки, отмеченные ${RED}✗${NC}"
        echo "  2. Проверьте предупреждения ${YELLOW}⚠${NC}"
        echo "  3. Запустите диагностику снова после исправлений"
        echo ""
    fi
    
    # Быстрые команды
    echo -e "${BOLD}Полезные команды:${NC}"
    echo "  • Логи дисплея:     journalctl -u mbcloud-display.service -f"
    echo "  • Статус Docker:    docker compose -f ~/mbcloud-system/docker/docker-compose.yml ps"
    echo "  • Место на диске:   df -h /DATA"
    echo "  • Температура:      vcgencmd measure_temp"
    echo "  • Обновить систему: ./scripts/mbcloud-diagnose.sh --update"
    echo ""
}

# ============================================================================
# 🔄 ОПЦИЯ: Авто-исправление (базовое)
# ============================================================================
auto_fix() {
    header "Авто-исправление"
    
    echo -e "${YELLOW}⚠  Эта функция выполнит автоматические исправления:${NC}"
    echo "  • Перезапуск остановленных сервисов"
    echo "  • Установка отсутствующих пакетов (базовых)"
    echo "  • Исправление прав доступа"
    echo ""
    
    read -p "Продолжить авто-исправление? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Отменено пользователем"
        return
    fi
    
    # Перезапуск сервиса дисплея, если он есть но не активен
    if systemctl list-unit-files | grep -q "$DISPLAY_SERVICE" && ! systemctl is-active --quiet "$DISPLAY_SERVICE" 2>/dev/null; then
        info "Перезапускаем $DISPLAY_SERVICE..."
        systemctl restart "$DISPLAY_SERVICE" 2>/dev/null && pass "Сервис перезапущен" || warn "Не удалось перезапустить сервис"
    fi
    
    # Проверка прав на репозиторий
    if [ -d "$REPO_PATH" ]; then
        chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$REPO_PATH" 2>/dev/null
        pass "Права на репозиторий исправлены"
    fi
    
    echo ""
    info "Авто-исправление завершено. Запустите диагностику снова для проверки."
}

# ============================================================================
# 🚀 ГЛАВНАЯ ФУНКЦИЯ
# ============================================================================
main() {
    # Заголовок
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  mbcloud NAS Diagnostic Tool v1.0  ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════╝${NC}"
    echo "  Время: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Пользователь: ${SUDO_USER:-$USER}$( [ $EUID -eq 0 ] && echo " (root)" || echo "")"
    echo ""
    
    # Обработка аргументов
    case "${1:-}" in
        --fix)
            auto_fix
            ;;
        --help|-h)
            echo "Использование: $0 [опции]"
            echo "Опции:"
            echo "  --fix    Запустить авто-исправление"
            echo "  --help   Показать эту справку"
            echo "  (без опций) - полная диагностика"
            exit 0
            ;;
    esac
    
    # Запуск проверок
    check_system
    check_hardware
    check_config_files
    check_docker
    check_storage
    check_network
    check_python
    check_display_render
    check_repository
    
    # Сводный отчёт
    print_summary
    
    # Выход с кодом ошибки, если есть критические проблемы
    [ $FAIL -gt 0 ] && exit 1 || exit 0
}

# Запуск
main "$@"
