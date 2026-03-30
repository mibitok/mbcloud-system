# mbcloud NAS

Домашнее облачное хранилище для синхронизации фото с iPhone.

## Структура
- `/scripts` — скрипты установки и утилиты
- `/config` — конфигурационные файлы
- `/docker` — Docker Compose конфигурации
- `/display` — код для 2" LCD дисплея
- `/docs` — документация

## Быстрый старт
1. Настроить ОС (Debian 12 Raspberry Pi OS)
2. Запустить `scripts/install-base.sh`
3. Настроить Docker и запустить `docker-compose up -d`
