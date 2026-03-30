#!/bin/bash
# scripts/install-base.sh
# Базовая настройка Debian 12 для mbcloud NAS (BCM2711, Raspberry Pi)

set -e  # Выход при любой ошибке

echo "🔄 Обновление системы..."
sudo apt update && sudo apt upgrade -y

echo "📦 Установка базовых утилит..."
sudo apt install -y \
    git curl wget htop tmux \
    smartmontools mergerfs \
    python3-pip python3-venv \
    libjpeg-dev zlib1g-dev \
    libatlas-base-dev

echo "🐳 Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker $USER
    echo "⚠️  Для применения группы docker требуется перезагрузка или: newgrp docker"
fi

echo "🔧 Настройка GPIO и SPI (для дисплея)..."
# Включаем SPI и I2C через raspi-config или напрямую
sudo raspi-config nonint do_spi 0
sudo raspi-config nonint do_i2c 0

echo "⚙️ Настройка mergerfs..."
sudo apt install -y mergerfs
# Создаём точку монтирования
sudo mkdir -p /DATA
# Добавляем в fstab (пример - нужно адаптировать под UUID дисков)
# /dev/disk/by-uuid/XXX:/dev/disk/by-uuid/YYY /DATA fuse.mergerfs defaults,allow_other,use_ino,category.create=epff 0 0

echo "🔥 Настройка вентилятора (GPIO 18 PWM)..."
# Создаём udev правило для доступа к GPIO
echo 'SUBSYSTEM=="gpio", KERNEL=="gpio*", MODE="0660", GROUP="gpio"' | sudo tee /etc/udev/rules.d/99-gpio.rules

echo "✅ Базовая настройка завершена!"
echo "👉 Следующий шаг: настройте диски и запустите 'docker-compose up -d' в папке /docker"
