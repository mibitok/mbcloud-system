#!/bin/bash
#==============================================================================
# mbcloud-system - setup-disks.sh v1.1.0 (FIXED)
# Фундаментальный этап: Подготовка SSD, MergerFS и Swap
# Исправления: 
# - Удалена опция 'failover' (не поддерживается в Debian Bookworm)
# - Добавлено автоматическое монтирование sda/sdb в /mnt/disk1/2 через fstab
#
# Использование:
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-disks.sh) -- --auto
#==============================================================================

set -eo pipefail

# 🎨 Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG_FILE="/var/log/mbcloud-disks.log"

# ⚙️ Настройки по умолчанию
DISK1="${DISK1:-}"; DISK2="${DISK2:-}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
DATA_MOUNT="${DATA_MOUNT:-/DATA}"
MOUNT1="${MOUNT1:-/mnt/disk1}"; MOUNT2="${MOUNT2:-/mnt/disk2}"
FS_TYPE="ext4"
MODE="interactive"; DRY_RUN="false"

# 📝 Логирование
log() { echo -e "${BLUE}[ℹ]${NC} $1" | tee -a "$LOG_FILE"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1" | tee -a "$LOG_FILE"; }
log_err() { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE" >&2; }
header() { echo -e "\n${GREEN}════════════════════════════════════════${NC}\n${GREEN}  $1${NC}\n${GREEN}════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"; }

# 🔍 Проверки
check_root() { [[ $EUID -eq 0 ]] || { log_err "Запустите с sudo"; exit 1; }; }

install_deps() {
    for pkg in lsblk mkfs.ext4 wipefs mergerfs; do
        if ! command -v $pkg &>/dev/null; then
            log "Устанавливаем зависимости..."
            apt update -qq && apt install -y -qq util-linux e2fsprogs mergerfs 2>/dev/null || { log_err "Ошибка установки пакетов"; exit 1; }
            break
        fi
    done
}

# 💿 Работа с дисками
get_sata_disks() {
    lsblk -dn -o NAME,TYPE 2>/dev/null | grep -E "disk$" | awk '{print "/dev/"$1}' | grep -vE "mmcblk|loop|ram"
}

wipe_disk() {
    local disk="$1"
    [[ "$DRY_RUN" == "true" ]] && { log "[DRY-RUN] Очистка $disk"; return 0; }
    log "Очищаем метаданные на $disk..."
    wipefs -a "$disk" 2>/dev/null || true
    # Удаляем разделы если есть
    for part in $(lsblk -n "$disk" -o NAME 2>/dev/null | grep -E "^${disk#/dev/}"); do
        umount "/dev/$part" 2>/dev/null || true
        wipefs -a "/dev/$part" 2>/dev/null || true
    done
    log_ok "$disk очищен"
}

format_and_mount_temp() {
    local disk="$1" mount_point="$2" label="$3"
    [[ -z "$disk" ]] && return 1
    
    header "📦 Форматирование: $disk → $mount_point"
    
    # Отмонтирование если занято
    if mount | grep -q "$disk"; then
        log_warn "$disk смонтирован, отмонтируем..."
        umount "$disk" 2>/dev/null || umount "${disk}1" 2>/dev/null || true
    fi
    
    wipe_disk "$disk"
    
    [[ "$DRY_RUN" == "true" ]] && { log "[DRY-RUN] mkfs.$FS_TYPE -L $label $disk"; return 0; }
    
    log "Форматируем в $FS_TYPE ($label)..."
    if mkfs.$FS_TYPE -F -L "$label" "$disk" 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "$disk отформатирован"
    else
        log_err "Ошибка форматирования $disk"; return 1
    fi
    
    mkdir -p "$mount_point"
    # Временное монтирование для проверки
    if mount "$disk" "$mount_point" 2>/dev/null; then
        log_ok "$disk временно смонтирован в $mount_point"
        chown -R 1000:1000 "$mount_point" 2>/dev/null || true
    else
        log_warn "Не удалось временно смонтировать $disk"
    fi
}

# 🔄 Запись дисков в fstab (КРИТИЧНО ИСПРАВЛЕНИЕ)
add_disks_to_fstab() {
    header "📝 Добавление дисков в /etc/fstab"
    
    local disk="$1" mount_point="$2"
    if [[ -z "$disk" ]]; then return 0; fi
    
    # Получаем UUID
    local uuid=$(blkid -s UUID -o value "$disk" 2>/dev/null)
    if [[ -z "$uuid" ]]; then
        log_err "Не удалось получить UUID для $disk"
        return 1
    fi
    
    # Проверяем, нет ли уже записи для этого UUID или точки монтирования
    if grep -q "$uuid" /etc/fstab 2>/dev/null || grep -q "$mount_point" /etc/fstab 2>/dev/null; then
        log_ok "$disk уже есть в fstab"
        return 0
    fi
    
    # Бэкап fstab
    local backup="/etc/fstab.mbcloud.disks.$(date +%Y%m%d%H%M%S)"
    cp /etc/fstab "$backup" && log "Бэкап fstab: $backup"
    
    # Добавляем запись
    echo "UUID=$uuid  $mount_point  ext4  defaults,noatime  0  2" >> /etc/fstab
    log_ok "Добавлен $disk ($uuid) в $mount_point"
}

# 🔄 MergerFS
setup_mergerfs() {
    header "🔄 Настройка MergerFS"
    
    # Проверка наличия записи
    if grep -q "fuse.mergerfs" /etc/fstab 2>/dev/null; then
        log_ok "MergerFS уже настроен в fstab."
        return 0
    fi
    
    # Создаем точку /DATA
    mkdir -p "$DATA_MOUNT"
    
    # Бэкап fstab (если еще не был сделан при добавлении дисков)
    if [[ ! -f "/etc/fstab.mbcloud.disks"* ]]; then
        local backup="/etc/fstab.mbcloud.disks.$(date +%Y%m%d%H%M%S)"
        cp /etc/fstab "$backup"
    fi
    
    # Добавление записи MergerFS (без failover!)
    {
        echo ""
        echo "# mbcloud NAS - MergerFS pool ($(date '+%Y-%m-%d'))"
        echo "${MOUNT1}:${MOUNT2} ${DATA_MOUNT} fuse.mergerfs defaults,allow_other,use_ino,category.create=mfs,_netdev,x-systemd.requires=network-online.target 0 0"
    } >> /etc/fstab
    
    log "Добавлена запись MergerFS в fstab."
}

# 💭 Swap
setup_swap() {
    header "💭 Настройка Swap ($SWAP_SIZE)"
    
    local swap_file="${DATA_MOUNT}/swapfile"
    # Если /DATA еще не готов, используем корень
    [[ ! -d "$DATA_MOUNT" ]] && swap_file="/swapfile" && log_warn "/DATA недоступен, swap будет в корне"
    
    # Проверка активности
    if swapon --show 2>/dev/null | grep -q "$swap_file"; then
        log_ok "Swap уже активен: $swap_file"
        return 0
    fi
    
    # Отключаем старый swap в корне если есть
    if [[ -f "/swapfile" ]] && swapon --show | grep -q "/swapfile"; then
        swapoff /swapfile && rm -f /swapfile && log "Старый swap удален"
    fi
    
    [[ "$DRY_RUN" == "true" ]] && { log "[DRY-RUN] Создание swap $SWAP_SIZE в $swap_file"; return 0; }
    
    log "Создаем swap-файл..."
    mkdir -p "$(dirname "$swap_file")"
    if fallocate -l "$SWAP_SIZE" "$swap_file" 2>/dev/null || dd if=/dev/zero of="$swap_file" bs=1M count=$(echo $SWAP_SIZE | sed 's/G/*1024/g') 2>/dev/null; then
        chmod 600 "$swap_file"
        mkswap "$swap_file" 2>&1 | tee -a "$LOG_FILE"
        swapon "$swap_file" 2>&1 | tee -a "$LOG_FILE" && log_ok "Swap активирован"
    else
        log_err "Не удалось создать swap"
        return 1
    fi
    
    # Добавление в fstab
    if ! grep -q "$swap_file" /etc/fstab 2>/dev/null; then
        echo "$swap_file none swap sw 0 0" >> /etc/fstab
        log_ok "Swap добавлен в fstab"
    fi
}

# 🎯 Main Logic
main() {
    exec > >(tee -a "$LOG_FILE") 2>&1
    check_root
    install_deps
    
    # Парсинг аргументов
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) MODE="auto"; shift ;;
            --dry-run) DRY_RUN="true"; shift ;;
            --disk1) DISK1="$2"; shift 2 ;;
            --disk2) DISK2="$2"; shift 2 ;;
            --swap) SWAP_SIZE="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    header "💾 mbcloud Disk Setup v1.1.0"
    
    # Определение дисков
    if [[ -z "$DISK1" ]]; then
        local disks=($(get_sata_disks))
        if [[ ${#disks[@]} -eq 0 ]]; then
            log_err "SATA диски не найдены!"
            exit 1
        fi
        
        if [[ "$MODE" == "auto" ]]; then
            DISK1="${disks[0]}"
            [[ ${#disks[@]} -ge 2 ]] && DISK2="${disks[1]}"
            log "Авто-выбор: DISK1=$DISK1, DISK2=${DISK2:-нет}"
        else
            # Для pipe-режима по умолчанию берем первый диск
            DISK1="${disks[0]}"
            [[ ${#disks[@]} -ge 2 ]] && DISK2="${disks[1]}"
            log_warn "В режиме pipe используется авто-выбор первых двух дисков."
        fi
    fi

    # 1. Форматирование и временное монтирование
    format_and_mount_temp "$DISK1" "$MOUNT1" "mbcloud1"
    [[ -n "$DISK2" ]] && format_and_mount_temp "$DISK2" "$MOUNT2" "mbcloud2"
    
    # 2. Добавление дисков в fstab (чтобы они монтировались после ребута)
    add_disks_to_fstab "$DISK1" "$MOUNT1"
    [[ -n "$DISK2" ]] && add_disks_to_fstab "$DISK2" "$MOUNT2"
    
    # 3. Настройка MergerFS
    setup_mergerfs
    
    # 4. Настройка Swap
    setup_swap
    
    # 5. Финальное монтирование всего
    header "🔧 Применение изменений fstab"
    systemctl daemon-reload
    if mount -a 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "Все файловые системы смонтированы"
    else
        log_err "Ошибка при монтировании! Проверьте /etc/fstab"
    fi
    
    header "✅ Готово"
    log "Проверьте статус: df -h /DATA && free -h"
    log "Лог: $LOG_FILE"
    
    if mountpoint -q "$DATA_MOUNT"; then
        local size=$(df -h "$DATA_MOUNT" | tail -1 | awk '{print $2}')
        log_ok "Объем хранилища /DATA: $size"
    else
        log_warn "/DATA не смонтирован. Требуется reboot."
    fi
    
    echo -e "${YELLOW}💡 Рекомендуется: sudo reboot${NC}"
}

main "$@"
