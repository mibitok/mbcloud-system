#!/bin/bash
#===============================================================================
# mbcloud NAS - Диагностика дисплея
# Проверяет: сервис, SPI, GPIO, шрифты, зависимости, логи
#===============================================================================

set -u

# 🎨 Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ⚙️ Пути
REPO_PATH="${HOME}/mbcloud-system"
DISPLAY_PATH="$REPO_PATH/display"
MAIN_PY="$DISPLAY_PATH/main.py"
FONTS_PATH="$DISPLAY_PATH/fonts"
SERVICE="mbcloud-display.service"
USER="${SUDO_USER:-$(whoami)}"

# 📊 Счётчики
PASS=0
FAIL=0
WARN=0

# ============================================================================
# 📢 ФУНКЦИИ ВЫВОДА
# ============================================================================
pass() { echo -e "  ${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC} $1 ${YELLOW}($2)${NC}"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; ((WARN++)); }
info() { echo -e "  ${BLUE}ℹ${NC} $1"; }
header() {
    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  mbcloud DISPLAY DIAGNOSTICS${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════${NC}"
    echo "  Время: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Пользователь: $USER"
    echo ""
}

# ============================================================================
# 🔍 ПРОВЕРКИ
# ============================================================================

check_service() {
    echo -e "\n${BOLD}▶ Сервис дисплея${NC}"
    
    if systemctl list-unit-files | grep -q "$SERVICE"; then
        pass "Сервис $SERVICE зарегистрирован"
        
        if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
            pass "Сервис активен (running)"
        else
            status=$(systemctl is-active "$SERVICE" 2>/dev/null || echo "unknown")
            fail "Сервис не активен: $status" "sudo systemctl start $SERVICE"
        fi
    else
        fail "Сервис $SERVICE не зарегистрирован" "sudo bash $REPO_PATH/scripts/setup-mbcloud.sh"
    fi
}

check_spi() {
    echo -e "\n${BOLD}▶ SPI интерфейс${NC}"
    
    if [ -c /dev/spidev0.0 ]; then
        pass "SPI устройство: /dev/spidev0.0"
    else
        fail "SPI устройство не найдено" "проверьте dtparam=spi=on в /boot/firmware/config.txt"
    fi
    
    if [ -c /dev/spidev0.1 ]; then
        pass "SPI устройство: /dev/spidev0.1"
    else
        warn "SPI устройство /dev/spidev0.1 не найдено"
    fi
    
    # Проверка config.txt
    if grep -q "^dtparam=spi=on" /boot/firmware/config.txt 2>/dev/null; then
        pass "SPI включён в config.txt"
    else
        fail "SPI не включён в config.txt" "добавьте: dtparam=spi=on"
    fi
}

check_i2c() {
    echo -e "\n${BOLD}▶ I2C интерфейс (для RTC)${NC}"
    
    if [ -c /dev/i2c-1 ]; then
        pass "I2C устройство: /dev/i2c-1"
    else
        fail "I2C устройство не найдено" "проверьте dtparam=i2c_arm=on"
    fi
    
    # Проверка RTC
    if command -v i2cdetect &>/dev/null; then
        if i2cdetect -y 1 2>/dev/null | grep -qE "51|68"; then
            pass "RTC обнаружен на шине I2C"
        else
            warn "RTC не обнаружен (адрес 0x51 или 0x68)"
        fi
    else
        info "i2cdetect не установлен (sudo apt install i2c-tools)"
    fi
}

check_gpio() {
    echo -e "\n${BOLD}▶ GPIO доступ${NC}"
    
    # Проверка группы gpio
    if groups "$USER" | grep -q gpio; then
        pass "Пользователь в группе gpio"
    else
        warn "Пользователь не в группе gpio" "sudo usermod -aG gpio $USER"
    fi
    
    # Проверка пинов (только чтение, безопасно)
    for pin in 24 25 18 26 20; do
        if [ -r /sys/class/gpio/gpio$pin/value ] 2>/dev/null; then
            info "GPIO $pin доступен"
        fi
    done
}

check_fonts() {
    echo -e "\n${BOLD}▶ Шрифты${NC}"
    
    if [ -d "$FONTS_PATH" ]; then
        pass "Папка шрифтов существует: $FONTS_PATH"
    else
        fail "Папка шрифтов не найдена" "$FONTS_PATH"
    fi
    
    # Проверка baveuse_0.ttf
    if [ -f "$FONTS_PATH/baveuse_0.ttf" ]; then
        size=$(stat -c%s "$FONTS_PATH/baveuse_0.ttf" 2>/dev/null || echo 0)
        if [ "$size" -gt 1000 ]; then
            pass "Шрифт baveuse_0.ttf: $size байт"
            
            # Тест загрузки
            if python3 -c "from PIL import ImageFont; ImageFont.truetype('$FONTS_PATH/baveuse_0.ttf', 24)" 2>/dev/null; then
                pass "Шрифт загружается корректно"
            else
                fail "Шрифт не может быть загружен PIL" "возможно повреждён"
            fi
        else
            fail "Шрифт baveuse_0.ttf пустой или слишком мал ($size байт)" "перескачайте шрифт"
        fi
    else
        fail "Шрифт baveuse_0.ttf не найден" "проверьте путь в main.py"
    fi
}

check_python() {
    echo -e "\n${BOLD}▶ Python зависимости${NC}"
    
    # Проверка Python
    if command -v python3 &>/dev/null; then
        py_ver=$(python3 --version 2>&1)
        pass "Python 3: $py_ver"
    else
        fail "Python 3 не установлен" "sudo apt install python3"
        return
    fi
    
    # Проверка модулей
    for pkg in psutil gpiozero PIL; do
        if python3 -c "import $pkg" 2>/dev/null; then
            pass "Python модуль: $pkg"
        else
            fail "Python модуль: $pkg" "pip3 install --user $pkg"
        fi
    done
}

check_main_py() {
    echo -e "\n${BOLD}▶ Файл main.py${NC}"
    
    if [ -f "$MAIN_PY" ]; then
        pass "Файл main.py найден: $MAIN_PY"
        
        # Проверка синтаксиса
        if python3 -m py_compile "$MAIN_PY" 2>/dev/null; then
            pass "Синтаксис Python: OK"
        else
            fail "Ошибка синтаксиса в main.py" "python3 -m py_compile $MAIN_PY"
        fi
        
        # Проверка пути к шрифту
        if grep -q "baveuse_0.ttf" "$MAIN_PY"; then
            pass "Путь к шрифту: baveuse_0.ttf ✓"
        elif grep -q "Baveuse.ttf" "$MAIN_PY"; then
            fail "Путь к шрифту: Baveuse.ttf (устарел)" "исправьте на baveuse_0.ttf"
        else
            warn "Путь к шрифту не найден в main.py"
        fi
        
        # Проверка порога вентилятора
        if grep -q "FAN_TEMP_THRESHOLD = 70" "$MAIN_PY"; then
            pass "Порог вентилятора: 70°C ✓"
        elif grep -q "FAN_TEMP_THRESHOLD = 45" "$MAIN_PY"; then
            info "Порог вентилятора: 45°C (старое значение)"
        fi
    else
        fail "Файл main.py не найден" "$MAIN_PY"
    fi
}

check_logs() {
    echo -e "\n${BOLD}▶ Логи сервиса${NC}"
    
    # Последние 10 строк логов
    logs=$(journalctl -u "$SERVICE" -n 10 --no-pager 2>/dev/null)
    
    if echo "$logs" | grep -qi "error\|failed\|traceback"; then
        fail "В логах есть ошибки:"
        echo "$logs" | grep -i "error\|failed\|traceback" | head -5 | while read line; do
            echo "    $line"
        done
    else
        pass "В логах нет критических ошибок"
    fi
    
    # Проверка на "GPIO busy"
    if echo "$logs" | grep -qi "gpio busy"; then
        warn "GPIO занят (возможно, другой процесс использует пины)"
        info "Попробуйте: sudo systemctl restart $SERVICE"
    fi
    
    # Проверка на "unknown file format"
    if echo "$logs" | grep -qi "unknown file format"; then
        fail "Ошибка шрифта: unknown file format" "проверьте файл шрифта"
    fi
}

check_display_render() {
    echo -e "\n${BOLD}▶ Тест рендеринга${NC}"
    
    if [ ! -f "$MAIN_PY" ]; then
        warn "main.py не найден, пропускаем тест"
        return
    fi
    
    # Тест импорта функций
    result=$(python3 -c "
import sys
sys.path.insert(0, '$DISPLAY_PATH')
try:
    from main import draw_sleep_screen, draw_page_dashboard
    img = draw_sleep_screen()
    if img and img.size == (320, 240):
        print('OK')
    else:
        print(f'SIZE:{img.size if img else None}')
except Exception as e:
    print(f'ERROR:{str(e)[:80]}')
" 2>&1)
    
    if [[ "$result" == "OK" ]]; then
        pass "Функции отрисовки работают"
    elif [[ "$result" == SIZE:* ]]; then
        warn "Неверный размер: ${result#SIZE:}"
    elif [[ "$result" == ERROR:* ]]; then
        fail "Ошибка рендеринга: ${result#ERROR:}"
    else
        info "Тест: $result"
    fi
}

# ============================================================================
# 📋 СВОДНЫЙ ОТЧЁТ
# ============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  СВОДНЫЙ ОТЧЁТ${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${BOLD}Результаты:${NC}"
    echo -e "  ${GREEN}✓ Успешно:${NC}  $PASS"
    echo -e "  ${RED}✗ Ошибки:${NC}   $FAIL"
    echo -e "  ${YELLOW}⚠ Предупреждения:${NC} $WARN"
    echo ""
    
    if [ $FAIL -eq 0 ]; then
        echo -e "${GREEN}${BOLD}🎉 ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ!${NC}"
        echo "Дисплей должен работать корректно."
    else
        echo -e "${RED}${BOLD}⚠ НАЙДЕНЫ ПРОБЛЕМЫ${NC}"
        echo "Исправьте $FAIL ошибок для работы дисплея."
    fi
    
    echo ""
    echo -e "${BOLD}Полезные команды:${NC}"
    echo "  • Перезапуск:     sudo systemctl restart $SERVICE"
    echo "  • Логи:           journalctl -u $SERVICE -f"
    echo "  • Статус:         sudo systemctl status $SERVICE"
    echo "  • Остановить:     sudo systemctl stop $SERVICE"
    echo ""
}

# ============================================================================
# 🚀 ГЛАВНАЯ ФУНКЦИЯ
# ============================================================================
main() {
    header
    
    check_service
    check_spi
    check_i2c
    check_gpio
    check_fonts
    check_python
    check_main_py
    check_logs
    check_display_render
    
    print_summary
    
    [ $FAIL -gt 0 ] && exit 1 || exit 0
}

main "$@"
