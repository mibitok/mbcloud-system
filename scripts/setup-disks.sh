#!/bin/bash
#==============================================================================
# mbcloud-system - setup-disks.sh
# Настройка SSD дисков и swap памяти для домашнего NAS
# Версия: 1.0.0
#
# Использование:
#   sudo bash setup-disks.sh                    # Интерактивный режим
#   sudo bash setup-disks.sh --auto             # Авто-настройка (первый найденный диск)
#   sudo bash setup-disks.sh --disk1 /dev/sda --disk2 /dev/sdb --swap 4G
#   sudo bash setup-disks.sh --dry-run          # Показать, что будет сделано
#   sudo bash setup-disks.sh --format-only      # Только форматирование, без fstab
#   sudo bash setup-disks.sh --swap-only        # Только настройка swap
#==============================================================================

set -eo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG_FILE="/var/log/mbcloud-disks.log"

# Переменные по умолчанию
DISK1="${DISK1:-}"
DISK2="${DISK2:-}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
DATA_MOUNT="${DATA_MOUNT:-/DATA}"
MOUNT1="${MOUNT1:-/mnt/disk1}"
MOUNT2="${MOUNT2:-/mnt/disk2}"
FS_TYPE="${FS_TYPE:-ext4}"
MODE="interactive"
DRY_RUN="false"
FORMAT_ONLY="false"
SWAP_ONLY="false"

#------------------------------------------------------------------------------
# 📝 ЛОГИРОВАНИЕ
#------------------------------------------------------------------------------
log() { echo -e "${BLUE}[ℹ]${NC} $1" | tee -a "$LOG_FILE"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1" | tee -a "$LOG_FILE"; }
log_err() { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE" >&2; }
header() { echo -e "\n${GREEN}════════════════════════════════════════${NC}\n${GREEN}  $1${NC}\n${GREEN}════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"; }

#------------------------------------------------------------------------------
# 🔍 ПРОВЕРКИ
#------------------------------------------------------------------------------
check_root() { [[ $EUID -eq 0 ]] || { log_err "Запустите с sudo"; exit 1; }; }

check_block_tools() {
    for cmd in lsblk mkfs.$FS_TYPE swapoff swapon blkid; do
        command -v $cmd &>/dev/null || { log "Устанавливаем $cmd..."; apt update -qq && apt install -y -qq util-linux e2fsprogs 2>/dev/null || log_warn "Не установлен: $cmd"; }
    done
}

#------------------------------------------------------------------------------
# 💿 СПИСОК ДИСКОВ
#------------------------------------------------------------------------------
list_available_disks() {
    header "🔍 Доступные диски"
    echo "Блочные устройства (исключая loop/ram):"
    echo "─────────────────────────────────────"
    lsblk -dn -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL 2>/dev/null | grep -vE "loop|ram" || echo "  Нет доступных дисков"
    echo "─────────────────────────────────────"
}

get_sata_disks() {
    # Возвращает список SATA/USB дисков (sda, sdb, nvme...)
    lsblk -dn -o NAME,TYPE 2>/dev/null | grep -E "disk$" | awk '{print "/dev/"$1}' | grep -vE "mmcblk|loop"
}

disk_has_partitions() {
    local disk="$1"
    lsblk -n "$disk" 2>/dev/null | grep -q "part" && return 0 || return 1
}

disk_is_mounted() {
    local disk="$1"
    mount | grep -q "^$disk" && return 0 || return 1
}

#------------------------------------------------------------------------------
# 🗑️ ОЧИСТКА ДИСКА
#------------------------------------------------------------------------------
wipe_disk() {
    local disk="$1"
    [[ "$DRY_RUN" == "true" ]] && { log "[DRY-RUN] Очистка $disk (wipefs)"; return 0; }
    
    log "Очищаем метаданные на $disk..."
    wipefs -a "$disk" 2>/dev/null || true
    # Удаляем разделы, если есть
    if disk_has_partitions "$disk"; then
        log "Удаляем разделы на $disk..."
        for part in $(lsblk -n "$disk" -o NAME | grep -E "^${disk#/dev/}"); do
            umount "/dev/$part" 2>/dev/null || true
            wipefs -a "/dev/$part" 2>/dev/null || true
        done
    fi
    log_ok "$disk очищен"
}

#------------------------------------------------------------------------------
# 📦 ФОРМАТИРОВАНИЕ
#------------------------------------------------------------------------------
format_disk() {
    local disk="$1" mount_point="$2" label="$3"
    [[ -z "$disk" ]] && { log_warn "Диск не указан"; return 1; }
    
    header "📦 Форматирование: $disk → $mount_point"
    
    # Проверки
    if ! lsblk "$disk" &>/dev/null; then
        log_err "Диск $disk не найден"; return 1
    fi
    if disk_is_mounted "$disk"; then
        log_warn "$disk смонтирован, отмонтируем..."
        umount "$disk" 2>/dev/null || umount "${disk}1" 2>/dev/null || true
    fi
    
    # Очистка
    wipe_disk "$disk"
    
    # Форматирование
    [[ "$DRY_RUN" == "true" ]] && { log "[DRY-RUN] mkfs.$FS_TYPE -L $label $disk"; return 0; }
    
    log "Форматируем в $FS_TYPE с меткой $label..."
    if mkfs.$FS_TYPE -F -L "$label" "$disk" 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "$disk отформатирован"
    else
        log_err "Ошибка форматирования $disk"
        return 1
    fi
    
    # Создание точки монтирования
    mkdir -p "$mount_point"
    
    # Монтирование для проверки
    if mount "$disk" "$mount_point" 2>/dev/null; then
        log_ok "$disk смонтирован в $mount_point"
        chown -R "$SUDO_USER:$SUDO_USER" "$mount_point" 2>/dev/null || true
    else
        log_warn "Не удалось смонтировать $disk (возможно, потребуется перезагрузка или правка fstab)"
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# 🔄 MERGERFS FSTAB ENTRY
#------------------------------------------------------------------------------
setup_mergerfs_fstab() {
    [[ "$FORMAT_ONLY" == "true" || "$SWAP_ONLY" == "true" ]] && return 0
    header "🔄 Настройка MergerFS в /etc/fstab"
    
    # Проверка: уже есть запись?
    if grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        log_ok "MergerFS уже настроен в fstab"
        return 0
    fi
    
    # Проверка: диски смонтированы?
    if [[ ! -d "$MOUNT1" || ! -d "$MOUNT2" ]]; then
        log_warn "Точки монтирования $MOUNT1 или $MOUNT2 не существуют"
        log "Создаём их..."
        mkdir -p "$MOUNT1" "$MOUNT2"
    fi
    
    # Бэкап fstab
    local backup="/etc/fstab.mbcloud.disks.$(date +%Y%m%d%H%M%S)"
    cp /etc/fstab "$backup" && log "Бэкап fstab: $backup"
    
    # Добавление записи
    {
        echo ""
        echo "# mbcloud NAS - MergerFS pool (добавлено $(date '+%Y-%m-%d %H:%M'))"
        echo "# Бэкап оригинала: $backup"
        echo "${MOUNT1}:${MOUNT2} ${DATA_MOUNT} fuse.mergerfs defaults,allow_other,use_ino,category.create=epff,_netdev,failover 0 0"
    } >> /etc/fstab
    
    log_ok "Запись MergerFS добавлена в /etc/fstab"
    
    # Тест монтирования
    if mount -a --no-mtab 2>&1 | grep -qi "error\|fail"; then
        log_err "⚠️  Ошибка при тестовом монтировании! Восстанавливаем fstab..."
        cp "$backup" /etc/fstab
        return 1
    else
        mount -a 2>/dev/null && log_ok "MergerFS успешно смонтирован в $DATA_MOUNT" || log_warn "MergerFS настроен — требуется перезагрузка для активации"
    fi
    
    return 0
}

#------------------------------------------------------------------------------
# 💭 НАСТРОЙКА SWAP
#------------------------------------------------------------------------------
setup_swap() {
    [[ "$SWAP_ONLY" == "false" && "$FORMAT_ONLY" == "true" ]] && return 0
    header "💭 Настройка swap памяти ($SWAP_SIZE)"
    
    local swap_file="/DATA/swapfile"
    
    # Если /DATA не существует — используем корень
    [[ ! -d "/DATA" ]] && swap_file="/swapfile" && log_warn "/DATA не найден, создаём swap в корне"
    
    # Проверка: swap уже активен?
    if swapon --show | grep -q "$swap_file"; then
        log_ok "Swap уже активен: $swap_file"
        return 0
    fi
    
    # Отключаем старые swap-файлы (опционально)
    if [[ -f "/swapfile" ]] && swapon --show | grep -q "/swapfile"; then
        log "Отключаем старый swap..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
    fi
    
    # Создание файла
    [[ "$DRY_RUN" == "true" ]] && { log "[DRY-RUN] fallocate -l $SWAP_SIZE $swap_file"; log "[DRY-RUN] chmod 600 $swap_file"; log "[DRY-RUN] mkswap $swap_file"; log "[DRY-RUN] swapon $swap_file"; return 0; }
    
    log "Создаём swap-файл $swap_file размером $SWAP_SIZE..."
    mkdir -p "$(dirname "$swap_file")"
    if fallocate -l "$SWAP_SIZE" "$swap_file" 2>/dev/null || dd if=/dev/zero of="$swap_file" bs=1M count="${SWAP_SIZE%G}"024 2>/dev/null; then
        chmod 600 "$swap_file"
        mkswap "$swap_file" 2>&1 | tee -a "$LOG_FILE"
        swapon "$swap_file" 2>&1 | tee -a "$LOG_FILE" && log_ok "Swap активирован: $swap_file"
    else
        log_err "Не удалось создать swap-файл"
        return 1
    fi
    
    # Добавление в fstab для постоянного включения
    if ! grep -q "$swap_file" /etc/fstab 2>/dev/null; then
        echo "# mbcloud swap (добавлено $(date '+%Y-%m-%d'))" >> /etc/fstab
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
        log_ok "Swap добавлен в /etc/fstab"
    fi
    
    # Проверка
    swapon --show && free -h | grep -i swap
    
    return 0
}

#------------------------------------------------------------------------------
# 📋 ИНТЕРАКТИВНЫЙ ВЫБОР ДИСКОВ
#------------------------------------------------------------------------------
interactive_select_disks() {
    header "🔧 Выбор дисков"
    local disks=($(get_sata_disks))
    
    if [[ ${#disks[@]} -eq 0 ]]; then
        log_err "Не найдено доступных SATA/USB дисков!"
        echo "Подключите диски и перезапустите скрипт."
        return 1
    fi
    
    echo "Найдены диски:"
    for i in "${!disks[@]}"; do
        local info=$(lsblk -dn -o SIZE,MODEL "${disks[$i]}" 2>/dev/null)
        echo "  [$((i+1))] ${disks[$i]} — $info"
    done
    echo "  [0] Ввести пути вручную"
    echo "─────────────────────────────────────"
    
    # Выбор DISK1
    read -p "Выберите диск для DISK1 (номер): " -n 1 -r; echo
    if [[ $REPLY =~ ^[1-9]$ ]] && [[ $REPLY -le ${#disks[@]} ]]; then
        DISK1="${disks[$((REPLY-1))]}"
    else
        read -p "Введите путь к DISK1 (например, /dev/sda): " DISK1
    fi
    
    # Выбор DISK2 (опционально)
    read -p "Добавить второй диск для MergerFS? (y/N): " -n 1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Оставшиеся диски:"
        for i in "${!disks[@]}"; do
            [[ "${disks[$i]}" == "$DISK1" ]] && continue
            local info=$(lsblk -dn -o SIZE,MODEL "${disks[$i]}" 2>/dev/null)
            echo "  [$((i+1))] ${disks[$i]} — $info"
        done
        read -p "Выберите диск для DISK2 (номер): " -n 1 -r; echo
        if [[ $REPLY =~ ^[1-9]$ ]] && [[ $REPLY -le ${#disks[@]} ]]; then
            DISK2="${disks[$((REPLY-1))]}"
        else
            read -p "Введите путь к DISK2 (например, /dev/sdb): " DISK2
        fi
    fi
    
    # Выбор размера swap
    read -p "Размер swap (по умолчанию $SWAP_SIZE): " -e -i "$SWAP_SIZE" SWAP_SIZE
    
    # Подтверждение
    echo "─────────────────────────────────────"
    echo "Будет выполнено:"
    echo "  • DISK1: $DISK1 → $MOUNT1"
    [[ -n "$DISK2" ]] && echo "  • DISK2: $DISK2 → $MOUNT2"
    echo "  • MergerFS: $MOUNT1${DISK2:+:$MOUNT2} → $DATA_MOUNT"
    echo "  • Swap: $SWAP_SIZE в $([ -d "/DATA" ] && echo "/DATA" || echo "/")/swapfile"
    echo "─────────────────────────────────────"
    read -p "Продолжить? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || return 1
    
    return 0
}

#------------------------------------------------------------------------------
# 🎯 MAIN
#------------------------------------------------------------------------------
main() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    check_root
    check_block_tools
    
    # Парсинг аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) MODE="auto"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            --format-only) FORMAT_ONLY="true"; shift ;;
            --swap-only) SWAP_ONLY="true"; shift ;;
            --disk1) DISK1="$2"; shift 2 ;;
            --disk2) DISK2="$2"; shift 2 ;;
            --swap) SWAP_SIZE="$2"; shift 2 ;;
            --help|-h)
                echo "Использование: $0 [опции]"
                echo "  --auto              Авто-выбор первого диска"
                echo "  --disk1 /dev/sda    Указать первый диск"
                echo "  --disk2 /dev/sdb    Указать второй диск"
                echo "  --swap 8G           Размер swap (по умолчанию 4G)"
                echo "  --dry-run           Показать, что будет сделано"
                echo "  --format-only       Только форматирование"
                echo "  --swap-only         Только настройка swap"
                exit 0
                ;;
            *) shift ;;
        esac
    done
    
    header "💾 mbcloud Disk Setup v1.0.0"
    list_available_disks
    
    # Авто-выбор дисков
    if [[ "$MODE" == "auto" && -z "$DISK1" ]]; then
        local disks=($(get_sata_disks))
        [[ ${#disks[@]} -ge 1 ]] && DISK1="${disks[0]}"
        [[ ${#disks[@]} -ge 2 ]] && DISK2="${disks[1]}"
        log "Авто-выбор: DISK1=$DISK1, DISK2=${DISK2:-не указан}"
    fi
    
    # Интерактивный выбор
    if [[ "$MODE" == "interactive" && (-z "$DISK1" || "$DISK1" == "select") ]]; then
        interactive_select_disks || { log "Отменено пользователем"; exit 0; }
    fi
    
    # Проверка ввода
    [[ -z "$DISK1" ]] && { log_err "DISK1 не указан. Используйте --disk1 /dev/sdX или интерактивный режим."; exit 1; }
    
    # Форматирование
    format_disk "$DISK1" "$MOUNT1" "mbcloud1"
    [[ -n "$DISK2" ]] && format_disk "$DISK2" "$MOUNT2" "mbcloud2"
    
    # MergerFS fstab
    setup_mergerfs_fstab
    
    # Swap
    setup_swap
    
    # Итог
    header "✅ Завершено"
    echo "Статус дисков:"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null | grep -E "disk1|disk2|DATA|swap" || true
    echo ""
    echo "Статус swap:"
    swapon --show 2>/dev/null || echo "  Swap не активен"
    echo ""
    log_ok "Лог операции: $LOG_FILE"
    
    if grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        echo -e "${YELLOW}💡 Рекомендуется перезагрузить систему: sudo reboot${NC}"
    fi
}

main "$@"
