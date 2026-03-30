#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mbcloud NAS - LCD Display Controller
240x240 SPI Display + GPIO Buttons + System Monitoring
"""

import time
import socket
import psutil
import threading
from datetime import datetime
from PIL import Image, ImageDraw, ImageFont
from gpiozero import Button, PWMOutputDevice

# ============================================================================
# ⚙️ КОНФИГУРАЦИЯ
# ============================================================================

# Параметры дисплея
DISPLAY_WIDTH = 240
DISPLAY_HEIGHT = 240
SPI_PORT = 0
SPI_DEVICE = 0

# GPIO пины (BCM numbering)
PIN_LCD_RST = 24
PIN_LCD_DC = 25
PIN_FAN_PWM = 18
PIN_BTN_PWR = 26  # Active LOW
PIN_BTN_USER = 20  # Active LOW

# Настройки
SLEEP_TIMEOUT = 60  # секунд бездействия до сна
FAN_TEMP_THRESHOLD = 45  # °C для включения вентилятора
FAN_MAX_SPEED = 0.8  # Максимальная скорость (0.0-1.0)

# Страницы интерфейса
TOTAL_PAGES = 5

# ============================================================================
# 🖥️ ИНИЦИАЛИЗАЦИЯ ДИСПЛЕЯ
# ============================================================================

# Попытка импорта драйвера дисплея (Waveshare или аналог)
try:
    # Для дисплеев Waveshare 240x240 (ST7789/ILI9341)
    from lib.lcd import LCD  # Путь зависит от вашей библиотеки
    disp = LCD(spi_port=SPI_PORT, spi_device=SPI_DEVICE, rst=PIN_LCD_RST, dc=PIN_LCD_DC)
    DISPLAY_AVAILABLE = True
except ImportError:
    print("⚠️  Драйвер дисплея не найден. Запуск в режиме эмуляции.")
    DISPLAY_AVAILABLE = False
    # Заглушка для тестов без железа
    class DummyDisplay:
        def ShowImage(self, img): pass
        def Init(self): pass
        def clear(self): pass
    disp = DummyDisplay()

# Инициализация вентилятора (PWM)
fan = PWMOutputDevice(PIN_FAN_PWM, frequency=25000)
fan.value = 0  # Старт с выключенным

# Кнопки с защитой от дребезга
btn_user = Button(PIN_BTN_USER, pull_up=True, bounce_time=0.2)
btn_pwr = Button(PIN_BTN_PWR, pull_up=True, bounce_time=0.2)

# ============================================================================
# 📊 СБОР СИСТЕМНЫХ ДАННЫХ
# ============================================================================

def get_ip():
    """Получить локальный IP-адрес"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "N/A"

def get_cpu_temp():
    """Температура CPU в °C"""
    try:
        with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
            return float(f.read()) / 1000
    except:
        return 0

def get_disk_usage(path):
    """Использование диска: (used, total, percent)"""
    try:
        usage = psutil.disk_usage(path)
        return usage.used, usage.total, usage.percent
    except:
        return 0, 1, 0

def get_ram():
    """Использование RAM: (used_gb, total_gb, percent)"""
    mem = psutil.virtual_memory()
    return mem.used / (1024**3), mem.total / (1024**3), mem.percent

def get_swap():
    """Использование Swap"""
    swap = psutil.swap_memory()
    return swap.used / (1024**3), swap.total / (1024**3), swap.percent

def get_cpu_load():
    """Загрузка CPU в %"""
    return psutil.cpu_percent(interval=0.5)

def get_uptime():
    """Время работы системы"""
    with open('/proc/uptime', 'r') as f:
        uptime_sec = float(f.readline().split()[0])
    days = int(uptime_sec // 86400)
    hours = int((uptime_sec % 86400) // 3600)
    mins = int((uptime_sec % 3600) // 60)
    return f"{days}d {hours:02d}:{mins:02d}"

def get_disk_info():
    """Информация о физических дисках"""
    disks = []
    for part in psutil.disk_partitions():
        if part.device.startswith('/dev/sd') or part.device.startswith('/dev/mmc'):
            try:
                usage = psutil.disk_usage(part.mountpoint)
                label = part.device.replace('/dev/', '')
                disks.append({
                    'name': label,
                    'mount': part.mountpoint,
                    'percent': usage.percent,
                    'used': usage.used / (1024**3),
                    'total': usage.total / (1024**3)
                })
            except:
                pass
    return disks

# ============================================================================
# 🎨 ОТРИСОВКА ЭЛЕМЕНТОВ ИНТЕРФЕЙСА
# ============================================================================

def get_font(size=12):
    """Получить шрифт (с фоллбэком)"""
    fonts = [
        f"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        f"/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
        None
    ]
    for font_path in fonts:
        try:
            if font_path:
                return ImageFont.truetype(font_path, size)
        except:
            continue
    return ImageFont.load_default()

def draw_progress_bar(draw, x, y, width, height, percent, color_fill, color_bg):
    """Рисует прогресс-бар"""
    # Фон
    draw.rectangle([x, y, x+width, y+height], outline=color_bg, fill=color_bg)
    # Заполнение
    fill_width = int(width * min(percent, 100) / 100)
    if fill_width > 0:
        draw.rectangle([x, y, x+fill_width, y+height], fill=color_fill)
    # Обводка
    draw.rectangle([x, y, x+width, y+height], outline=color_fill)

def draw_card(draw, x, y, w, h, title, content, color=(0, 255, 255)):
    """Рисует информационную карточку"""
    # Рамка
    draw.rectangle([x, y, x+w, y+h], outline=color, width=1)
    # Заголовок
    font_small = get_font(10)
    draw.text((x+4, y+2), title, font=font_small, fill=color)
    # Контент
    font_normal = get_font(14)
    draw.text((x+4, y+18), content, font=font_normal, fill=(255, 255, 255))

# ============================================================================
# 📄 СТРАНИЦЫ ИНТЕРФЕЙСА
# ============================================================================

def draw_page_dashboard():
    """Страница 1: Главная панель"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), color=(0, 0, 0))
    draw = ImageDraw.Draw(img)
    font_title = get_font(16)
    font_normal = get_font(14)
    
    # Заголовок
    draw.text((10, 5), "🏠 mbcloud NAS", font=font_title, fill=(0, 255, 255))
    
    # IP адрес
    ip = get_ip()
    draw.text((10, 30), f"🌐 {ip}", font=font_normal, fill=(255, 255, 255))
    
    # Температура CPU
    temp = get_cpu_temp()
    temp_color = (0, 255, 0) if temp < 50 else (255, 165, 0) if temp < 70 else (255, 0, 0)
    draw.text((10, 55), f"🌡️ CPU: {temp:.1f}°C", font=font_normal, fill=temp_color)
    
    # Загрузка CPU (прогресс-бар)
    cpu = get_cpu_load()
    draw.text((10, 85), f"⚡ CPU Load: {cpu:.0f}%", font=font_normal, fill=(255, 255, 255))
    draw_progress_bar(draw, 10, 100, 220, 15, cpu, (0, 200, 0), (50, 50, 50))
    
    # Время
    now = datetime.now().strftime("%H:%M:%S")
    draw.text((10, 125), f"🕐 {now}", font=font_normal, fill=(255, 255, 0))
    
    # Статус вентилятора
    fan_status = "ON" if fan.value > 0 else "OFF"
    draw.text((10, 150), f"💨 Fan: {fan_status}", font=font_normal, fill=(200, 200, 255))
    
    # Индикатор страниц (внизу)
    draw_progress_bar(draw, 0, 230, DISPLAY_WIDTH, 10, 20, (100, 100, 255), (30, 30, 30))
    
    return img

def draw_page_storage():
    """Страница 2: Физические диски"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), color=(0, 0, 0))
    draw = ImageDraw.Draw(img)
    font_title = get_font(14)
    font_small = get_font(11)
    
    draw.text((10, 5), "💾 Physical Disks", font=font_title, fill=(0, 255, 255))
    
    disks = get_disk_info()
    y = 30
    for i, disk in enumerate(disks[:3]):  # Показать максимум 3
        color = (0, 255, 100) if disk['percent'] < 80 else (255, 100, 0)
        name = disk['name'][:10]  # Обрезать имя
        draw.text((10, y), f"{name}", font=font_small, fill=color)
        draw.text((10, y+12), f"{disk['used']:.0f}/{disk['total']:.0f} GB", font=font_small, fill=(200, 200, 200))
        draw_progress_bar(draw, 10, y+28, 220, 10, disk['percent'], color, (40, 40, 40))
        y += 45
    
    return img

def draw_page_mergerfs():
    """Страница 3: Объединённое хранилище /DATA"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), color=(0, 0, 0))
    draw = ImageDraw.Draw(img)
    font_title = get_font(16)
    font_normal = get_font(14)
    
    draw.text((10, 5), "🗄️ MergerFS /DATA", font=font_title, fill=(0, 255, 255))
    
    used, total, percent = get_disk_usage('/DATA')
    
    # Большие цифры
    draw.text((10, 40), f"{used:.1f} GB", font=font_title, fill=(255, 255, 255))
    draw.text((10, 65), f"of {total:.1f} GB", font=font_normal, fill=(150, 150, 150))
    
    # Прогресс-бар
    draw.text((10, 100), f"Used: {percent:.1f}%", font=font_normal, fill=(255, 255, 255))
    bar_color = (0, 200, 0) if percent < 70 else (255, 165, 0) if percent < 90 else (255, 50, 50)
    draw_progress_bar(draw, 10, 120, 220, 25, percent, bar_color, (50, 50, 50))
    
    # Статус
    status = "✅ Healthy" if percent < 95 else "⚠️ Almost full!"
    draw.text((10, 160), status, font=font_normal, fill=(0, 255, 0) if percent < 95 else (255, 100, 100))
    
    return img

def draw_page_system():
    """Страница 4: Системные ресурсы"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), color=(0, 0, 0))
    draw = ImageDraw.Draw(img)
    font_title = get_font(14)
    font_small = get_font(11)
    
    draw.text((10, 5), "⚙️ System Resources", font=font_title, fill=(0, 255, 255))
    
    # RAM
    ram_used, ram_total, ram_pct = get_ram()
    draw.text((10, 30), f"🧠 RAM: {ram_used:.1f}/{ram_total:.1f} GB ({ram_pct:.0f}%)", font=font_small, fill=(255, 255, 255))
    draw_progress_bar(draw, 10, 45, 220, 12, ram_pct, (0, 150, 255), (40, 40, 40))
    
    # Swap
    swap_used, swap_total, swap_pct = get_swap()
    draw.text((10, 65), f"💿 Swap: {swap_used:.1f}/{swap_total:.1f} GB", font=font_small, fill=(200, 200, 200))
    draw_progress_bar(draw, 10, 80, 220, 12, swap_pct, (150, 150, 255), (40, 40, 40))
    
    # CPU Load
    cpu = get_cpu_load()
    draw.text((10, 100), f"⚡ CPU: {cpu:.0f}%", font=font_small, fill=(255, 255, 255))
    draw_progress_bar(draw, 10, 115, 220, 12, cpu, (0, 200, 0), (40, 40, 40))
    
    # Uptime
    uptime = get_uptime()
    draw.text((10, 140), f"⏱️ Uptime: {uptime}", font=font_small, fill=(255, 200, 100))
    
    # Температура
    temp = get_cpu_temp()
    draw.text((10, 160), f"🌡️ Temp: {temp:.1f}°C", font=font_small, fill=(0, 255, 0) if temp < 50 else (255, 100, 0))
    
    return img

def draw_page_info():
    """Страница 5: Системная информация"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), color=(0, 0, 0))
    draw = ImageDraw.Draw(img)
    font_title = get_font(14)
    font_small = get_font(11)
    
    draw.text((10, 5), "ℹ️ System Info", font=font_title, fill=(0, 255, 255))
    
    info_lines = [
        f"📦 Debian 12",
        f"🔧 BCM2711 A72",
        f"🌐 {get_ip()}",
        f"🕐 {datetime.now().strftime('%Y-%m-%d')}",
        f"⏱️ {get_uptime()}",
        f"🌡️ {get_cpu_temp():.1f}°C",
        f"💾 {get_disk_usage('/DATA')[2]:.0f}% /DATA",
        f"🐳 Docker: OK",
    ]
    
    y = 30
    for line in info_lines:
        draw.text((10, y), line, font=font_small, fill=(200, 200, 255))
        y += 18
    
    return img

def draw_sleep_screen():
    """Спящий режим: время + звёзды"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), color=(0, 0, 0))
    draw = ImageDraw.Draw(img)
    font_time = get_font(32)
    font_date = get_font(14)
    
    # Мерцающие звёзды (простая анимация через время)
    seed = int(time.time()) % 100
    for i in range(20):
        x = (seed + i * 17) % DISPLAY_WIDTH
        y = (seed + i * 23) % DISPLAY_HEIGHT
        if (seed + i) % 3 == 0:  # Каждая третья звезда мерцает
            draw.point((x, y), fill=(200, 200, 255))
    
    # Время крупно
    time_str = datetime.now().strftime("%H:%M")
    date_str = datetime.now().strftime("%a %d.%m")
    
    # Центрирование
    time_bbox = draw.textbbox((0, 0), time_str, font=font_time)
    time_x = (DISPLAY_WIDTH - time_bbox[2]) // 2
    
    draw.text((time_x, 70), time_str, font=font_time, fill=(0, 255, 255))
    draw.text((10, 140), date_str, font=font_date, fill=(150, 150, 255))
    
    # Подсказка
    draw.text((10, 220), "[USER] Wake", font=get_font(10), fill=(100, 100, 100))
    
    return img

# Список функций страниц
pages = [
    draw_page_dashboard,
    draw_page_storage,
    draw_page_mergerfs,
    draw_page_system,
    draw_page_info,
]

# ============================================================================
# 🎮 УПРАВЛЕНИЕ И СОСТОЯНИЕ
# ============================================================================

# Глобальные переменные состояния
display_on = True
current_page = 0
last_activity = time.time()

def update_display():
    """Обновить изображение на дисплее"""
    global display_on, current_page
    if not display_on:
        img = draw_sleep_screen()
    else:
        img = pages[current_page]()
    
    if DISPLAY_AVAILABLE:
        try:
            disp.ShowImage(img)
        except Exception as e:
            print(f"⚠️ Display error: {e}")

def next_page():
    """Переключить страницу или разбудить дисплей"""
    global display_on, current_page, last_activity
    last_activity = time.time()
    
    if not display_on:
        display_on = True
    else:
        current_page = (current_page + 1) % TOTAL_PAGES
    
    update_display()

def toggle_display():
    """Вкл/выкл дисплей"""
    global display_on, last_activity
    display_on = not display_on
    last_activity = time.time()
    update_display()

def shutdown_system():
    """Корректное выключение системы"""
    print("🔌 Shutdown requested...")
    update_display()  # Показать последнее состояние
    if DISPLAY_AVAILABLE:
        disp.clear()
    # Выполнить shutdown
    import os
    os.system("sudo shutdown -h now")

def control_fan():
    """Управление вентилятором на основе температуры"""
    temp = get_cpu_temp()
    if temp < FAN_TEMP_THRESHOLD:
        fan.value = 0  # Выключить
    else:
        # Плавное увеличение скорости с температурой
        speed = min(FAN_MAX_SPEED, 0.3 + (temp - FAN_TEMP_THRESHOLD) * 0.05)
        fan.value = speed

def check_sleep_timeout():
    """Фоновая проверка таймаута сна"""
    global display_on, last_activity
    while True:
        time.sleep(10)  # Проверка каждые 10 секунд
        if display_on and (time.time() - last_activity) > SLEEP_TIMEOUT:
            display_on = False
            update_display()

# ============================================================================
# 🔄 ОБРАБОТЧИКИ КНОПОК
# ============================================================================

def on_user_press():
    """Кнопка USER: следующая страница / пробуждение"""
    next_page()

def on_pwr_press():
    """Кнопка PWR: вкл/выкл дисплей"""
    toggle_display()

def on_pwr_hold():
    """Кнопка PWR (долгое нажатие): выключение"""
    shutdown_system()

# Настройка обработчиков кнопок
btn_user.when_pressed = on_user_press
btn_pwr.when_pressed = on_pwr_press
btn_pwr.when_held = on_pwr_hold
btn_pwr.hold_time = 2  # 2 секунды для shutdown

# ============================================================================
# 🚀 ГЛАВНЫЙ ЦИКЛ
# ============================================================================

def main():
    """Точка входа"""
    global display_on
    
    print("🖥️  mbcloud Display Controller starting...")
    
    # Инициализация дисплея
    if DISPLAY_AVAILABLE:
        try:
            disp.Init()
            disp.clear()
            print("✅ Display initialized")
        except Exception as e:
            print(f"⚠️ Display init failed: {e}")
    
    # Запуск потока проверки сна
    sleep_thread = threading.Thread(target=check_sleep_timeout, daemon=True)
    sleep_thread.start()
    
    # Первоначальная отрисовка
    update_display()
    
    print(f"✅ Running. Pages: {TOTAL_PAGES}, Sleep: {SLEEP_TIMEOUT}s")
    
    # Главный цикл
    try:
        while True:
            # Обновление вентилятора
            control_fan()
            
            # Обновление времени в спящем режиме (раз в минуту)
            if not display_on:
                update_display()
            
            time.sleep(0.1)  # Небольшая задержка для снижения нагрузки
            
    except KeyboardInterrupt:
        print("\n👋 Shutting down...")
        fan.value = 0
        if DISPLAY_AVAILABLE:
            disp.clear()
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    main()
