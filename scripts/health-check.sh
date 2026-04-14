#!/bin/bash
#===============================================================================
# mbcloud NAS - Health Check Script v1.0
# Использование: ~/mbcloud-system/scripts/health-check.sh
# Или: curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/health-check.sh | bash
#===============================================================================

# 🎨 Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 📢 Вывод
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_err() { echo -e "${RED}[✗]${NC} $1"; }
log_info() { echo -e "${BLUE}[→]${NC} $1"; }

header() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  🩺 mbcloud NAS Health Check       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

check_display() {
    log_info "Проверка дисплея..."
    if sudo systemctl is-active mbcloud-display.service &>/dev/null; then
        log_ok "Сервис дисплея: активен"
        # Проверка логов на ошибки
        if journalctl -u mbcloud-display.service -n 10 --no-pager 2>/dev/null | grep -qi "error\|fail"; then
            log_warn "В логах есть ошибки — проверьте: journalctl -u mbcloud-display.service -f"
        else
            log_ok "Логи: без ошибок"
        fi
    else
        log_err "Сервис дисплея: не активен"
        log_info "Запустите: sudo systemctl start mbcloud-display.service"
    fi
}

check_temperature() {
    log_info "Проверка температуры..."
    local temp=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2 | tr -d "'C")
    if [ -n "$temp" ]; then
        if (( $(echo "$temp < 60" | bc -l 2>/dev/null || echo 1) )); then
            log_ok "Температура: ${temp}°C (норма)"
        elif (( $(echo "$temp < 75" | bc -l 2>/dev/null || echo 1) )); then
            log_warn "Температура: ${temp}°C (повышена)"
        else
            log_err "Температура: ${temp}°C (критично!)"
        fi
    else
        log_warn "Не удалось получить температуру"
    fi
}

check_storage() {
    log_info "Проверка хранилища..."
    if [ -d "/DATA" ]; then
        local usage=$(df -h /DATA 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
        local free=$(df -h /DATA 2>/dev/null | tail -1 | awk '{print $4}')
        if [ -n "$usage" ]; then
            if [ "$usage" -lt 80 ]; then
                log_ok "Место на /DATA: ${free} свободно (${usage}% занято)"
            elif [ "$usage" -lt 95 ]; then
                log_warn "Место на /DATA: ${free} свободно (${usage}% занято) — очистите место!"
            else
                log_err "Место на /DATA: критически мало (${usage}% занято)!"
            fi
        fi
    else
        log_warn "/DATA не существует"
    fi
}

check_immich() {
    log_info "Проверка Immich..."
    if command -v docker &>/dev/null; then
        local containers=$(docker compose -f ~/mbcloud-system/docker/docker-compose.yml ps -q 2>/dev/null | wc -l)
        if [ "$containers" -gt 0 ]; then
            log_ok "Immich: $containers контейнеров запущено"
            # Проверка порта
            if sudo ss -tlnp 2>/dev/null | grep -q ":2283 "; then
                log_ok "Порт 2283: слушается"
            else
                log_warn "Порт 2283: не слушается (Immich может быть не готов)"
            fi
        else
            log_warn "Immich: контейнеры не запущены"
            log_info "Запустите: cd ~/mbcloud-system/docker && docker compose up -d"
        fi
    else
        log_warn "Docker: не установлен"
    fi
}

check_network() {
    log_info "Проверка сети..."
    local ip=$(hostname -I | awk '{print $1}')
    if [ -n "$ip" ]; then
        log_ok "IP адрес: $ip"
        # Проверка доступности из сети
        if ping -c 1 -W 1 "$ip" &>/dev/null; then
            log_ok "Сеть: устройство доступно"
        else
            log_warn "Сеть: возможны проблемы с подключением"
        fi
    else
        log_err "Не удалось определить IP адрес"
    fi
}

check_samba() {
    log_info "Проверка Samba..."
    if command -v smbpasswd &>/dev/null; then
        if sudo systemctl is-active smbd &>/dev/null; then
            log_ok "Samba: сервис активен"
            log_info "Доступ: \\\\${hostname -I | awk '{print $1}'}\\mbcloud"
        else
            log_warn "Samba: сервис не активен"
        fi
    else
        log_warn "Samba: не установлен"
    fi
}

print_summary() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo -e "${BLUE}  📊 ИТОГОВАЯ СТАТИСТИКА${NC}"
    echo -e "${BLUE}═══════════════════════════════════════${NC}"
    echo ""
    echo "🖥️  Дисплей: $(sudo systemctl is-active mbcloud-display.service 2>/dev/null || echo 'unknown')"
    echo "🌡️  Температура: $(vcgencmd measure_temp 2>/dev/null || echo 'N/A')"
    echo "💾  Хранилище: $(df -h /DATA 2>/dev/null | tail -1 | awk '{print $4 " free (" $5 " used)"}' || echo 'N/A')"
    echo "🐳  Immich: $(docker compose -f ~/mbcloud-system/docker/docker-compose.yml ps -q 2>/dev/null | wc -l) контейнеров"
    echo "🌐  Samba: $(sudo systemctl is-active smbd 2>/dev/null || echo 'unknown')"
    echo "🔗  IP: $(hostname -I | awk '{print $1}')"
    echo ""
    echo -e "${BLUE}Полезные команды:${NC}"
    echo "  • Логи дисплея:  ${BLUE}journalctl -u mbcloud-display.service -f${NC}"
    echo "  • Immich логи:   ${BLUE}cd ~/mbcloud-system/docker && docker compose logs -f${NC}"
    echo "  • Перезапуск:    ${BLUE}sudo systemctl restart mbcloud-display.service${NC}"
    echo "  • Температура:   ${BLUE}watch -n 2 vcgencmd measure_temp${NC}"
    echo ""
}

main() {
    header
    check_display
    check_temperature
    check_storage
    check_immich
    check_network
    check_samba
    print_summary
    echo -e "${GREEN}✅ Проверка завершена!${NC}"
}

main "$@"
