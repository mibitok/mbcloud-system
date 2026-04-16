# 🖥️ mbcloud NAS

**Домашний NAS на Raspberry Pi CM4 с дисплеем, умным вентилятором и фото-сервером Immich**

<p align="center">
  <img src="https://img.shields.io/badge/Platform-Raspberry%20Pi%20CM4-blue?style=for-the-badge&logo=raspberrypi" alt="Platform">
  <img src="https://img.shields.io/badge/OS-Raspberry%20Pi%20OS%20Bookworm-green?style=for-the-badge&logo=linux" alt="OS">
  <img src="https://img.shields.io/badge/Language-Python%203-yellow?style=for-the-badge&logo=python" alt="Language">
  <img src="https://img.shields.io/badge/License-MIT-orange?style=for-the-badge" alt="License">
</p>

---

## ✨ Возможности

| Компонент | Описание |
|-----------|----------|
| 🖥️ **Дисплей** | 2.4" IPS 320×240, шрифт Baveuse, 5 страниц мониторинга, спящий режим |
| 🌬️ **Умный вентилятор** | Авто-управление через GPIO 19 (sysfs), включение при > 60°C, плавный контроль |
| 💾 **Хранилище** | 2× SATA SSD/HDD, MergerFS объединение в `/DATA`, Samba доступ |
| 🐳 **Immich** | Фото-сервер как Google Photos, синхронизация с iPhone/Android |
| 🔧 **Авто-установка** | Одна команда для базовой системы + опциональные компоненты |
| 📊 **Диагностика** | Встроенный `health-check.sh` проверяет все компоненты |
| 🔄 **Авто-обновление** | Cron обновляет код с GitHub и перезапускает сервисы |
| 💾 **Авто-бэкапы** | Скрипты для резервного копирования Immich и системных данных |

---

## 📋 Системные требования

| Компонент | Минимум | Рекомендуется |
|-----------|---------|---------------|
| Плата | Raspberry Pi CM4 | CM4 4GB RAM + 32GB eMMC |
| Носитель | Waveshare CM4-NAS-Double-Deck | ✅ |
| Дисплей | Waveshare 2.4" IPS 320×240 | ✅ |
| Диски | 1× 2.5" SATA SSD/HDD | 2× 2.5" SATA SSD/HDD |
| Питание | 5V/3A USB-C | 5V/3.5A USB-C |
| ОС | Raspberry Pi OS Lite (64-bit, Bookworm) | ✅ |
| Сеть | Ethernet 1Gbps или Wi-Fi | Ethernet (для Immich) |

---

## 🚀 Быстрая установка

### Полный запуск за 1 минуту:

```bash
# 1. Подгатовка дисков
  # 1.1. Скачиваем скрипт в домашнюю папку
curl -fsSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-disks.sh -o ~/setup-disks.sh

  # 1.2. Делаем его исполняемым
chmod +x ~/setup-disks.sh

  # 1.3. Запускаем с правами root в автоматическом режиме (выберет sda и sdb)
sudo ~/setup-disks.sh --auto

  # 2. Базовая система (дисплей + вентилятор + Python)
curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/setup-mbcloud.sh | sudo bash

# 3. Рекомендуемые дополнения (Immich + MergerFS + авто-обновление)
curl -sSL https://raw.githubusercontent.com/mibitok/mbcloud-system/main/scripts/install-addons.sh | sudo bash -s -- --recommended

# 4. Диагностика
~/mbcloud-system/scripts/health-check.sh
