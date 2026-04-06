# 🔧 mbcloud NAS - Hardware Guide

Схема подключения и распиновка для **Waveshare CM4-NAS-Double-Deck**.

---

## 📦 Комплектующие

| Компонент | Модель | Примечание |
|-----------|--------|------------|
| Плата | Raspberry Pi Compute Module 4 | 4 ГБ RAM, 32 ГБ eMMC |
| Носитель | Waveshare CM4-NAS-Double-Deck | 2× SATA, LCD 2.4", GPIO |
| Дисплей | Waveshare 2.4" IPS 320×240 | SPI, 18-bit color |
| Вентилятор | 5V PWM 40mm | GPIO 19 управление |
| Диски | 2× 2.5" SATA SSD/HDD | До 8 ТБ каждый |
| Питание | 5V/3A USB-C | Минимум 3А для стабильной работы |

---

## 🔌 Распиновка ключевых подключений

### Дисплей (уже распаян на плате)
LCD → CM4-NAS-Double-Deck (встроенное подключение)
├─ MOSI → GPIO 10 (SPI0)
├─ MISO → GPIO 9 (SPI0)
├─ SCLK → GPIO 11 (SPI0)
├─ DC → GPIO 25
├─ RST → GPIO 24
├─ BL → GPIO 18 (PWM, подсветка)
└─ GND → Земля

### Вентилятор ⚠️ Важно!
FAN → CM4-NAS-Double-Deck разъём "FAN"
├─ Красный (5V) → 5V питание (всегда)
├─ Чёрный (GND) → Земля
├─ Жёлтый (PWM) → GPIO 19 (управление скоростью)
└─ Синий (TACH) → Не подключён (опционально)

⚠️ Конфликт: GPIO 19 = SPI0 MISO
Решение: Управление через sysfs, не через gpiozero/PWM библиотеки

### Кнопки
BTN_PWR → GPIO 26 (выключение системы, удержание 2 сек)
BTN_USER → GPIO 20 (переключение страниц дисплея)

RTC: PCF85063a → I2C адрес 0x51
Подключение: уже распаяно на плате
Настройка: dtoverlay=i2c-rtc,pcf85063a в config.txt

### SATA диски
SATA1 → /dev/sda → /mnt/disk1
SATA2 → /dev/sdb → /mnt/disk2
Объединение: MergerFS → /DATA

## 📐 Схема платы (вид сверху)
┌─────────────────────────────────────┐
│ CM4-NAS-Double-Deck │
│ ┌─────────────────────────────┐ │
│ │ [CM4 Socket] │ │
│ │ │ │
│ │ [LCD 2.4"] [FAN] [SATA1]│ │
│ │ │ │
│ │ [SATA2] [RTC] [GPIO] │ │
│ └─────────────────────────────┘ │
│ │
│ 🔘 Кнопки: │
│ • PWR (GPIO 26) - выключение │
│ • USER (GPIO 20) - смена страницы │
│ │
│ 🔌 Порты: │
│ • USB-C (питание + данные) │
│ • 2× SATA (диски) │
│ • GPIO header (расширение) │
└─────────────────────────────────────┘

---

## ⚙️ Настройка /boot/firmware/config.txt

Добавьте эти строки (или используйте `config/config.txt.additions`):

```ini
# SPI для дисплея
dtparam=spi=on

# I2C для RTC и датчиков
dtparam=i2c_arm=on

# RTC PCF85063a
dtoverlay=i2c-rtc,pcf85063a

# Отключить аудио (освобождает ресурсы)
dtparam=audio=off

# Опционально: увеличить частоту SPI
dtparam=spi_speed=40000000

sudo reboot
