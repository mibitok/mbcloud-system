#!/bin/bash
#===============================================================================
# mbcloud NAS - Auto-Update Script v1.0
# Использование: ~/mbcloud-system/scripts/update-mbcloud.sh
# cron: 0 4 * * * /home/mibitok/mbcloud-system/scripts/update-mbcloud.sh
#===============================================================================

REPO_PATH="${REPO_PATH:-/home/${SUDO_USER:-$(whoami)}/mbcloud-system}"
SERVICE="mbcloud-display.service"
LOG_FILE="/var/log/mbcloud-update.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

log "🔄 Начинаю обновление..."

# 📦 Обновляем системные пакеты (безопасные)
log "📦 Обновляем системные пакеты..."
if sudo apt update -qq && sudo apt upgrade -y -qq 2>/dev/null; then
    log_ok "✅ Системные пакеты обновлены"
else
    log_warn "⚠️  Ошибка обновления пакетов"
fi

# 🔄 Обновляем код репозитория
cd "$REPO_PATH" || { log_err "❌ Папка репозитория не найдена"; exit 1; }

if git pull -q 2>/dev/null; then
    log_ok "✅ Код репозитория обновлён"
    
    # 🔍 Проверяем, изменился ли main.py
    if git diff --name-only HEAD@{1}..HEAD 2>/dev/null | grep -q "display/main.py"; then
        log "🔄 main.py изменён — перезапускаем сервис..."
        if sudo systemctl restart "$SERVICE" 2>/dev/null; then
            log_ok "✅ Сервис $SERVICE перезапущен"
        else
            log_warn "⚠️  Ошибка перезапуска сервиса"
        fi
    fi
    
    # 📦 Проверяем, изменился ли requirements.txt
    if git diff --name-only HEAD@{1}..HEAD 2>/dev/null | grep -q "requirements.txt"; then
        log "📦 requirements.txt изменён — обновляем пакеты..."
        if sudo pip3 install -q --break-system-packages -r "$REPO_PATH/display/requirements.txt" 2>/dev/null; then
            log_ok "✅ Python-зависимости обновлены"
        else
            log_warn "⚠️  Ошибка обновления зависимостей"
        fi
    fi
else
    log_warn "⚠️  Ошибка git pull"
fi

# 🐳 Обновляем Immich образы (опционально)
if command -v docker &>/dev/null && [ -f "$REPO_PATH/docker/docker-compose.yml" ]; then
    log "🐳 Проверяем обновления Immich..."
    cd "$REPO_PATH/docker"
    if docker compose pull -q 2>/dev/null; then
        log_ok "✅ Immich образы проверены"
        # Авто-перезапуск контейнеров (раскомментируйте при необходимости)
        # docker compose up -d 2>/dev/null && log "✅ Immich перезапущен"
    else
        log_warn "⚠️  Ошибка обновления Immich образов"
    fi
fi

log "✅ Обновление завершено в $(date)"
exit 0
