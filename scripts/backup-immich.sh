#!/bin/bash
#===============================================================================
# mbcloud NAS - Immich Backup Script v1.0
# Использование: ~/mbcloud-system/scripts/backup-immich.sh
# cron: 0 3 * * 0 /home/mibitok/mbcloud-system/scripts/backup-immich.sh
#===============================================================================

# 📁 Настройки
BACKUP_DIR="/DATA/backups/immich"
IMMICH_DATA="/DATA/immich-upload /DATA/immich-library"
DB_BACKUP="$BACKUP_DIR/database-$(date +%Y%m%d).dump"
LOG_FILE="/var/log/mbcloud-immich-backup.log"
RETENTION_DAYS=30

# 📢 Логирование
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# 🔐 Проверка прав
if [[ $EUID -ne 0 ]]; then
    log "❌ Запустите с sudo"
    exit 1
fi

# 📁 Создаём папку бэкапа
mkdir -p "$BACKUP_DIR"

log "🔄 Начинаю бэкап Immich..."

# 🗄️ Бэкап базы данных
log "💾 Бэкап базы данных..."
if docker exec immich_postgres pg_dump -U immich -d immich > "$DB_BACKUP" 2>/dev/null; then
    log_ok "✅ База данных: $DB_BACKUP"
    # Сжимаем бэкап
    gzip "$DB_BACKUP" && log "🗜️  Сжато: ${DB_BACKUP}.gz"
else
    log_err "❌ Ошибка бэкапа базы данных"
    exit 1
fi

# 📸 Бэкап файлов (фото/видео)
log "📸 Бэкап файлов..."
for dir in $IMMICH_DATA; do
    if [ -d "$dir" ]; then
        tar -czf "$BACKUP_DIR/files-$(basename "$dir")-$(date +%Y%m%d).tar.gz" -C "$(dirname "$dir")" "$(basename "$dir")" 2>/dev/null && \
        log_ok "✅ Файлы: $(basename "$dir")" || \
        log_warn "⚠️  Ошибка бэкапа: $dir"
    fi
done

# 🗑️ Очистка старых бэкапов
log "🗑️  Удаляю бэкапы старше $RETENTION_DAYS дней..."
find "$BACKUP_DIR" -name "*.gz" -mtime +$RETENTION_DAYS -delete 2>/dev/null
log_ok "✅ Очистка завершена"

# 📊 Итог
log "📊 Размер бэкапа: $(du -sh "$BACKUP_DIR" | cut -f1)"
log "✅ Бэкап Immich завершён!"

# 🔔 Уведомление (если настроен Telegram)
if [ -x "/home/mibitok/mbcloud-system/scripts/notify-telegram.sh" ]; then
    /home/mibitok/mbcloud-system/scripts/notify-telegram.sh send "✅ Immich backup completed: $(du -sh "$BACKUP_DIR" | cut -f1)" 2>/dev/null || true
fi

exit 0
