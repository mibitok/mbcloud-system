#!/bin/bash
# scripts/install-base.sh
# Базовая настройка Debian 12 для mbcloud NAS

set -e  # Выход при ошибке

echo "🔄 Обновление системы..."
sudo apt update && sudo apt upgrade -y

echo "📦 Установка базовых пакетов..."
sudo apt install -y \
    git \
    curl \
    wget \
    htop \
    tmux \
    mergetools \
    smartmontools \
    samba \
    mergerfs

echo "🐳 Установка Docker..."
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

echo "✅ Базовая настройка завершена!"
