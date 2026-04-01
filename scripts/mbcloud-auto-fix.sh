#!/bin/bash
#===============================================================================
# mbcloud NAS - Автоматическое исправление типовых проблем
# Исправляет: шрифты, docker-compose, сервисы, права, репозиторий
# Использование: ./mbcloud-auto-fix.sh [--dry-run] [--verbose]
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
DISPLAY_PATH="$REPO_PATH/display"
DOCKER_PATH="$REPO_PATH/docker"
FONTS_PATH="$DISPLAY_PATH/fonts"
CONFIG_FILE="/boot/firmware/config.txt"
DISPLAY_SERVICE="mbcloud-display.service"
DATA_MOUNT="/DATA"
USER="${SUDO_USER:-$(whoami)}"

# Флаги
DRY_RUN=false
VERBOSE=false

# 📊 Счётчики
FIXED=0
SKIPPED=0
ERRORS=0

# ============================================================================
# 📢 ФУНКЦИИ ВЫВОДА
# ============================================================================
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; ((FIXED++)); }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((SKIPPED++)); }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; ((ERRORS++)); }
log_fix() { echo -e "${CYAN}[FIX]${NC} $1"; }

header() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  mbcloud AUTO-FIX v1.0             ║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════╝${NC}"
    echo "  Время: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Пользователь: $USER $([ $EUID -eq 0 ] && echo '(root)' || echo '')"
    echo "  Режим: $([ "$DRY_RUN" = true ] && echo "🔍 Dry-run" || echo "🔧 Auto-fix")"
    echo ""
}

# ============================================================================
# 🔧 ФУНКЦИИ ИСПРАВЛЕНИЯ
# ============================================================================

# Исправление пути к шрифту в main.py
fix_font_path() {
    echo -e "\n${CYAN}${BOLD}▶ Исправление пути к шрифту${NC}"
    
    local main_py="$DISPLAY_PATH/main.py"
    
    if [ ! -f "$main_py" ]; then
        log_err "Файл не найден: $main_py"
        return 1
    fi
    
    # Проверяем текущий путь
    if grep -q "baveuse_0.ttf" "$main_py"; then
        log_ok "Путь к шрифту уже корректен (baveuse_0.ttf)"
        return 0
    fi
    
    if grep -q "Baveuse.ttf" "$main_py"; then
        log_fix "Исправляем путь: Baveuse.ttf → baveuse_0.ttf"
        
        if [ "$DRY_RUN" = true ]; then
            log "🔍 [DRY-RUN] sed -i 's/Baveuse.ttf/baveuse_0.ttf/g' $main_py"
            log_ok "Исправление выполнено (dry-run)"
            return 0
        fi
        
        # Создаём резервную копию
        cp "$main_py" "${main_py}.backup.$(date +%Y%m%d%H%M)"
        
        # Исправляем путь
        sed -i 's|Baveuse\.ttf|baveuse_0.ttf|g' "$main_py"
        
        # Проверяем результат
        if grep -q "baveuse_0.ttf" "$main_py"; then
            log_ok "Путь к шрифту исправлен"
            
            # Проверка синтаксиса Python
            if python3 -m py_compile "$main_py" 2>/dev/null; then
                log_ok "Синтаксис main.py: OK"
            else
                log_warn "Возможная ошибка синтаксиса в main.py"
            fi
            
            return 0
        else
            log_err "Не удалось исправить путь к шрифту"
            return 1
        fi
    else
        log_warn "Не найдено упоминание Baveuse.ttf в main.py"
        return 0
    fi
}

# Удаление пустого файла-заглушки шрифта
cleanup_font_file() {
    echo -e "\n${CYAN}${BOLD}▶ Очистка файлов шрифтов${NC}"
    
    local empty_font="$FONTS_PATH/Baveuse.ttf"
    local real_font="$FONTS_PATH/baveuse_0.ttf"
    
    # Проверяем реальный шрифт
    if [ -f "$real_font" ] && [ -s "$real_font" ]; then
        local size=$(stat -c%s "$real_font" 2>/dev/null || echo 0)
        log_ok "Рабочий шрифт: baveuse_0.ttf ($size байт)"
    else
        log_warn "Рабочий шрифт не найден или пуст: $real_font"
    fi
    
    # Удаляем пустой файл-заглушку
    if [ -f "$empty_font" ]; then
        local size=$(stat -c%s "$empty_font" 2>/dev/null || echo 0)
        if [ "$size" -eq 0 ]; then
            log_fix "Удаляем пустой файл: $empty_font"
            if [ "$DRY_RUN" = true ]; then
                log "🔍 [DRY-RUN] rm -f $empty_font"
            else
                rm -f "$empty_font"
            fi
            log_ok "Пустой файл удалён"
        else
            log_info "Файл $empty_font не пустой ($size байт) — оставляем"
        fi
    else
        log_ok "Пустой файл-заглушка не найден (уже удалён)"
    fi
    
    # Проверка загрузки шрифта
    if [ -f "$real_font" ] && [ -s "$real_font" ]; then
        log "Тестируем загрузку шрифта..."
        if python3 -c "from PIL import ImageFont; ImageFont.truetype('$real_font', 24)" 2>/dev/null; then
            log_ok "Шрифт загружается корректно"
        else
            log_warn "Шрифт не может быть загружен PIL (возможно, повреждён)"
        fi
    fi
}

# Исправление docker-compose.yml (удаление SHA256)
fix_docker_compose() {
    echo -e "\n${CYAN}${BOLD}▶ Исправление docker-compose.yml${NC}"
    
    local compose_file="$DOCKER_PATH/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        log_err "Файл не найден: $compose_file"
        return 1
    fi
    
    # Проверяем наличие @sha256:
    if ! grep -q "@sha256:" "$compose_file"; then
        log_ok "docker-compose.yml уже не содержит @sha256: хешей"
        return 0
    fi
    
    log_fix "Удаляем @sha256:... из образов Docker"
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 [DRY-RUN] sed -i 's/@sha256:[a-f0-9]*//g' $compose_file"
        log_ok "Исправление выполнено (dry-run)"
        return 0
    fi
    
    # Резервная копия
    cp "$compose_file" "${compose_file}.backup.$(date +%Y%m%d%H%M)"
    
    # Удаляем хеши (оставляем только теги версий)
    sed -i 's/@sha256:[a-f0-9]*//g' "$compose_file"
    
    # Проверяем результат
    if ! grep -q "@sha256:" "$compose_file"; then
        log_ok "Хеши SHA256 удалены из образов"
        
        # Валидация YAML (если есть yq или python)
        if command -v python3 &>/dev/null; then
            if python3 -c "import yaml; yaml.safe_load(open('$compose_file'))" 2>/dev/null; then
                log_ok "YAML синтаксис: OK"
            else
                log_warn "Возможная ошибка YAML в docker-compose.yml"
            fi
        fi
        
        return 0
    else
        log_err "Не удалось удалить все хеши SHA256"
        return 1
    fi
}

# Перезапуск сервиса дисплея
restart_display_service() {
    echo -e "\n${CYAN}${BOLD}▶ Перезапуск сервиса дисплея${NC}"
    
    if ! systemctl list-unit-files | grep -q "$DISPLAY_SERVICE"; then
        log_warn "Сервис $DISPLAY_SERVICE не зарегистрирован"
        return 1
    fi
    
    log_fix "Перезапускаем $DISPLAY_SERVICE..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 [DRY-RUN] systemctl restart $DISPLAY_SERVICE"
        log_ok "Перезапуск выполнен (dry-run)"
        return 0
    fi
    
    if systemctl restart "$DISPLAY_SERVICE" 2>/dev/null; then
        sleep 2
        if systemctl is-active --quiet "$DISPLAY_SERVICE" 2>/dev/null; then
            log_ok "Сервис перезапущен и активен"
            
            # Проверка логов на ошибки
            if journalctl -u "$DISPLAY_SERVICE" -n 5 --no-pager 2>/dev/null | grep -qi "error\|failed"; then
                log_warn "В логах сервиса есть ошибки (проверьте: journalctl -u $DISPLAY_SERVICE)"
            else
                log_ok "Логи сервиса: чисто"
            fi
            
            return 0
        fi
    fi
    
    log_err "Не удалось перезапустить сервис"
    return 1
}

# Перезапуск Immich контейнеров
restart_immich() {
    echo -e "\n${CYAN}${BOLD}▶ Перезапуск Immich (Docker)${NC}"
    
    local compose_file="$DOCKER_PATH/docker-compose.yml"
    
    if [ ! -f "$compose_file" ]; then
        log_warn "docker-compose.yml не найден, пропускаем Immich"
        return 0
    fi
    
    log_fix "Обновляем и перезапускаем Immich stack..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🔍 [DRY-RUN] cd $DOCKER_PATH && docker compose pull && docker compose up -d"
        log_ok "Перезапуск выполнен (dry-run)"
        return 0
    fi
    
    cd "$DOCKER_PATH"
    
    # Скачиваем образы
    log "Скачиваем образы..."
    if docker compose pull -q 2>/dev/null; then
        log_ok "Образы обновлены"
    else
        log_warn "Не все образы скачаны (проверьте интернет/архитектуру)"
    fi
    
    # Запускаем контейнеры
    log "Запускаем контейнеры..."
    if docker compose up -d 2>/dev/null; then
        sleep 3
        
        # Проверка статуса
        local running=$(docker compose ps --format json 2>/dev/null | grep -c '"Running":true' || echo 0)
        local total=$(docker compose ps --format json 2>/dev/null | grep -c '"Name":' || echo 0)
        
        if [ "$running" -gt 0 ]; then
            log_ok "Контейнеры запущены: $running/$total"
            docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null | tail -n +2 | while read line; do
                log "  • $line"
            done
        else
            log_warn "Контейнеры не запущены (проверьте: docker compose ps)"
        fi
    else
        log_err "Не удалось запустить контейнеры"
        return 1
    fi
    
    return 0
}

# Проверка и настройка прав
fix_permissions() {
    echo -e "\n${CYAN}${BOLD}▶ Настройка прав доступа${NC}"
    
    # Права на репозиторий
    if [ -d "$REPO_PATH" ]; then
        log_fix "Исправляем права на $REPO_PATH..."
        if [ "$DRY_RUN" = true ]; then
            log "🔍 [DRY-RUN] chown -R $USER:$USER $REPO_PATH"
        else
            chown -R "$USER:$USER" "$REPO_PATH" 2>/dev/null || true
        fi
        log_ok "Права на репозиторий настроены"
    fi
    
    # Права на /DATA
    if [ -d "$DATA_MOUNT" ]; then
        log_fix "Исправляем права на $DATA_MOUNT..."
        if [ "$DRY_RUN" = true ]; then
            log "🔍 [DRY-RUN] chown -R $USER:$USER $DATA_MOUNT"
        else
            chown -R "$USER:$USER" "$DATA_MOUNT" 2>/dev/null || true
        fi
        log_ok "Права на хранилище настроены"
    fi
    
    # Группа gpio для пользователя
    if ! groups "$USER" | grep -q gpio; then
        log_warn "Пользователь не в группе gpio"
        if [ "$DRY_RUN" = false ]; then
            if usermod -aG gpio "$USER" 2>/dev/null; then
                log_ok "Пользователь добавлен в группу gpio (требуется перезагрузка)"
            fi
        fi
    else
        log_ok "Пользователь в группе gpio"
    fi
    
    # Группа docker для пользователя
    if ! groups "$USER" | grep -q docker; then
        log_warn "Пользователь не в группе docker"
        if [ "$DRY_RUN" = false ]; then
            if usermod -aG docker "$USER" 2>/dev/null; then
                log_ok "Пользователь добавлен в группу docker (выполните: newgrp docker)"
            fi
        fi
    else
        log_ok "Пользователь в группе docker"
    fi
}

# Проверка репозитория
fix_repository() {
    echo -e "\n${CYAN}${BOLD}▶ Проверка репозитория${NC}"
    
    if [ ! -d "$REPO_PATH/.git" ]; then
        log_warn "Git репозиторий не найден в $REPO_PATH"
        return 1
    fi
    
    cd "$REPO_PATH"
    
    # Проверка незакоммиченных изменений
    if git status --porcelain 2>/dev/null | grep -q .; then
        log_warn "Есть незакоммиченные изменения:"
        git status --porcelain 2>/dev/null | head -5 | while read line; do
            log "  • $line"
        done
        echo "  ... и ещё $(git status --porcelain 2>/dev/null | wc -l) изменений"
    else
        log_ok "Рабочее дерево чистое"
    fi
    
    # Проверка обновлений
    if git fetch --dry-run 2>/dev/null | grep -q .; then
        log_warn "Есть обновления в удалённом репозитории"
        log_info "Выполните: cd $REPO_PATH && git pull"
    else
        log_ok "Репозиторий актуален"
    fi
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
    echo -e "  ${GREEN}✓ Исправлено:${NC}  $FIXED"
    echo -e "  ${YELLOW}⚠ Предупреждения:${NC} $SKIPPED"
    echo -e "  ${RED}✗ Ошибки:${NC}   $ERRORS"
    echo ""
    
    if [ $ERRORS -eq 0 ]; then
        echo -e "${GREEN}${BOLD}🎉 ВСЕ ИСПРАВЛЕНИЯ УСПЕШНЫ!${NC}"
        echo "Система должна работать корректно."
    else
        echo -e "${RED}${BOLD}⚠ ЕСТЬ ОШИБКИ${NC}"
        echo "Проверьте сообщения выше и исправьте вручную."
    fi
    
    echo ""
    echo -e "${BOLD}Полезные команды для проверки:${NC}"
    echo "  • Дисплей:      journalctl -u $DISPLAY_SERVICE -f"
    echo "  • Immich:       docker compose -f $DOCKER_PATH/docker-compose.yml ps"
    echo "  • Веб-доступ:   curl -I http://localhost:2283"
    echo "  • Хранилище:    df -h $DATA_MOUNT"
    echo "  • Шрифт:        python3 -c \"from PIL import ImageFont; print('OK')\""
    echo "  • Перезагрузка: sudo reboot"
    echo ""
}

# ============================================================================
# 🚀 ГЛАВНАЯ ФУНКЦИЯ
# ============================================================================
main() {
    # Парсинг аргументов
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run|-n) DRY_RUN=true; shift ;;
            --verbose|-v) VERBOSE=true; shift ;;
            --help|-h)
                echo "Использование: $0 [опции]"
                echo "Опции:"
                echo "  --dry-run, -n  Показать, что будет сделано, без изменений"
                echo "  --verbose, -v  Подробный вывод"
                echo "  --help, -h     Показать эту справку"
                exit 0
                ;;
            *) shift ;;
        esac
    done
    
    # Проверка прав
    if [ $EUID -ne 0 ]; then
        echo -e "${YELLOW}[WARN]${NC} Для полной функциональности запустите с sudo"
        echo "Пример: sudo $0 $*"
        echo ""
    fi
    
    header
    
    # Запуск исправлений
    fix_font_path
    cleanup_font_file
    fix_docker_compose
    fix_permissions
    restart_display_service
    restart_immich
    fix_repository
    
    # Финальный отчёт
    print_summary
    
    # Код выхода
    [ $ERRORS -gt 0 ] && exit 1 || exit 0
}

# Запуск
main "$@"
