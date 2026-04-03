#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mbcloud NAS - LCD Display Controller
CM4-NAS-Double-Deck (Waveshare 2.4" IPS 320x240)
Ретро-стиль 70-х + шрифт Baveuse
"""

import sys
import os
import time
import socket
import psutil
import threading
from datetime import datetime
from PIL import Image, ImageDraw, ImageFont

# ============================================================================
# ⚙️ КОНФИГУРАЦИЯ
# ============================================================================
DISPLAY_WIDTH = 320
DISPLAY_HEIGHT = 240
DISPLAY_ROTATION = 180  # Поворот экрана (0, 90, 180, 270)

# 🎨 ЦВЕТА (ретро-палитра)
COLOR_BG = (0, 0, 0)
COLOR_TIME = (0, 255, 100)
COLOR_TIME_GLOW = (0, 100, 40)
COLOR_DATE = (0, 200, 200)
COLOR_TEXT = (255, 255, 255)
COLOR_WARN = (255, 165, 0)
COLOR_ERROR = (255, 50, 50)

# 🔘 Пины GPIO
PIN_LCD_RST = 24
PIN_LCD_DC = 25
PIN_FAN_PWM = 18
PIN_BTN_PWR = 26
PIN_BTN_USER = 20

# ⚙️ Настройки
SLEEP_TIMEOUT = 60
FAN_TEMP_THRESHOLD = 70  # 🔥 Порог включения вентилятора (70°C)
FAN_MAX_SPEED = 0.8
TOTAL_PAGES = 5

# 🔤 Пути к шрифтам
FONT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fonts')
BAVEUSE_FONT = os.path.join(FONT_PATH, 'baveuse_0.ttf')

# ============================================================================
# 🖥️ ИНИЦИАЛИЗАЦИЯ ДИСПЛЕЯ
# ============================================================================
DISPLAY_AVAILABLE = False
disp = None

waveshare_path = '/home/mibitok/CM4-NAS-Double-Deck_Demo/RaspberryPi'
if waveshare_path not in sys.path:
    sys.path.insert(0, waveshare_path)

try:
    from lib.LCD_2inch import LCD_2inch
    disp = LCD_2inch()
    disp.Init()
    disp.clear()
    DISPLAY_AVAILABLE = True
    print("✅ Waveshare LCD_2inch initialized")
except Exception as e:
    print(f"⚠️  Display init failed: {e}")
    class DummyDisplay:
        def Init(self): pass
        def clear(self): pass
        def ShowImage(self, img): print(f"🖼️  Display: {img.size if img else 'None'}")
    disp = DummyDisplay()

# ============================================================================
# 💨 ВЕНТИЛЯТОР
# ============================================================================
try:
    from gpiozero import PWMOutputDevice
    fan = PWMOutputDevice(PIN_FAN_PWM, frequency=100)
    fan.value = 0
    print("✅ Fan PWM initialized at 100Hz")
except Exception as e:
    print(f"⚠️  Fan init failed: {e}")
    class DummyFan:
        value = 0
    fan = DummyFan()

# ============================================================================
# 🔘 КНОПКИ
# ============================================================================
try:
    from gpiozero import Button
    btn_user = Button(PIN_BTN_USER, pull_up=True, bounce_time=0.2)
    btn_pwr = Button(PIN_BTN_PWR, pull_up=True, bounce_time=0.2)
    print("✅ Buttons initialized")
except Exception as e:
    print(f"⚠️  Button init failed: {e}")
    class DummyButton:
        def __init__(self, *args, **kwargs): pass
        when_pressed = None
        when_held = None
        hold_time = 0
    btn_user = btn_pwr = DummyButton()

# ============================================================================
# 🔤 ШРИФТЫ
# ============================================================================
def get_font(size=14, bold=False, custom_path=None, cyrillic=False):
    """Получить шрифт с фоллбэком"""
    # Для кириллицы используем DejaVu
    if cyrillic:
        for path in [
            f"/usr/share/fonts/truetype/dejavu/DejaVuSans{'-Bold' if bold else ''}.ttf",
            f"/usr/share/fonts/truetype/liberation/LiberationSans{'-Bold' if bold else ''}.ttf",
        ]:
            if path and os.path.exists(path):
                try:
                    return ImageFont.truetype(path, size)
                except:
                    continue
        return ImageFont.load_default()
    
    # Для цифр/латиницы пробуем Baveuse
    if custom_path and os.path.exists(custom_path):
        try:
            return ImageFont.truetype(custom_path, size)
        except:
            pass
    
    # Фоллбэк на стандартные
    for path in [
        f"/usr/share/fonts/truetype/dejavu/DejaVuSans{'-Bold' if bold else ''}.ttf",
        f"/usr/share/fonts/truetype/liberation/LiberationSans{'-Bold' if bold else ''}.ttf",
        None
    ]:
        try:
            if path and os.path.exists(path):
                return ImageFont.truetype(path, size)
        except:
            continue
    return ImageFont.load_default()

# ============================================================================
# 📊 СИСТЕМНЫЕ ФУНКЦИИ
# ============================================================================
def get_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except:
        return "N/A"

def get_cpu_temp():
    try:
        with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
            return float(f.read()) / 1000
    except:
        return 0

def get_disk_usage(path):
    try:
        u = psutil.disk_usage(path)
        return u.used, u.total, u.percent
    except:
        return 0, 1, 0

def get_ram():
    m = psutil.virtual_memory()
    return m.used/(1024**3), m.total/(1024**3), m.percent

def get_cpu_load():
    return psutil.cpu_percent(interval=0.3)

def get_uptime():
    try:
        with open('/proc/uptime') as f:
            sec = float(f.read().split()[0])
        d, h, m = int(sec//86400), int((sec%86400)//3600), int((sec%3600)//60)
        return f"{d}d {h:02d}:{m:02d}"
    except:
        return "N/A"

def draw_progress(draw, x, y, w, h, pct, fg, bg):
    """Рисует прогресс-бар"""
    draw.rectangle([x, y, x+w, y+h], fill=bg, outline=fg)
    fw = int(w * min(pct, 100) / 100)
    if fw > 0:
        draw.rectangle([x, y, x+fw, y+h], fill=fg)

# ============================================================================
# 🕰️ СПЯЩИЙ РЕЖИМ (Ретро-часы со шрифтом Baveuse)
# ============================================================================
def draw_sleep_screen():
    """Ретро-часы: Baveuse font, дата внизу, декор"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), COLOR_BG)
    draw = ImageDraw.Draw(img)
    now = datetime.now()
    
    # ─── ВРЕМЯ (шрифт Baveuse, крупно по центру) ─────────────────────────
    time_str = now.strftime("%H:%M")
    font_time = get_font(72, custom_path=BAVEUSE_FONT)
    
    try:
        bbox = draw.textbbox((0, 0), time_str, font=font_time)
        time_x = (DISPLAY_WIDTH - bbox[2]) // 2
        time_y = (DISPLAY_HEIGHT - bbox[3]) // 2 - 10
    except:
        time_x, time_y = 40, 60
        font_time = get_font(48)
    
    # Эффект свечения
    for dx in [-2, -1, 0, 1, 2]:
        for dy in [-2, -1, 0, 1, 2]:
            if dx == 0 and dy == 0:
                continue
            draw.text((time_x+dx, time_y+dy), time_str, font=font_time, fill=COLOR_TIME_GLOW)
    
    draw.text((time_x, time_y), time_str, font=font_time, fill=COLOR_TIME)
    
    # ─── ДАТА (внизу по ширине) ───────────────────────────────────────────
    date_str = now.strftime("%A, %d %B %Y")
    font_date = get_font(18, custom_path=BAVEUSE_FONT, cyrillic=True)
    
    try:
        bbox = draw.textbbox((0, 0), date_str, font=font_date)
        date_x = (DISPLAY_WIDTH - bbox[2]) // 2
    except:
        date_x = 10
        font_date = get_font(14)
    
    for dx in [-1, 0, 1]:
        for dy in [-1, 0, 1]:
            if dx == 0 and dy == 0:
                continue
            draw.text((date_x+dx, DISPLAY_HEIGHT - 30 + dy), date_str, font=font_date, fill=(0, 50, 50))
    
    draw.text((date_x, DISPLAY_HEIGHT - 30), date_str, font=font_date, fill=COLOR_DATE)
    
    # ─── ДЕКОР (звёзды + сетка) ───────────────────────────────────────────
    seed = now.hour * 100 + now.minute
    for i in range(25):
        sx = (seed + i * 37) % DISPLAY_WIDTH
        sy = (seed + i * 53) % (time_y - 20)
        br = 200 if i % 5 == 0 else 100
        sz = 2 if i % 7 == 0 else 1
        draw.ellipse([sx, sy, sx+sz, sy+sz], fill=(br, br, 220))
    
    for gx in range(0, DISPLAY_WIDTH, 40):
        draw.line([(gx, 0), (gx, time_y-10)], fill=(25, 25, 50), width=1)
    
    # ─── СТАТУС (углы) ────────────────────────────────────────────────────
    temp = get_cpu_temp()
    tc = COLOR_TIME if temp < 50 else COLOR_WARN if temp < 70 else COLOR_ERROR
    draw.text((8, 5), f"TMP {temp:.0f}C", font=get_font(11), fill=tc)
    
    try:
        dp = psutil.disk_usage('/DATA').percent
        draw.text((DISPLAY_WIDTH - 70, 5), f"DSK {dp:.0f}%", font=get_font(11), fill=COLOR_TEXT)
    except:
        pass
    
    return img

# ============================================================================
# 📄 СТРАНИЦЫ ИНТЕРФЕЙСА
# ============================================================================
def draw_page_dashboard():
    """Страница 1: Главная"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), COLOR_BG)
    draw = ImageDraw.Draw(img)
    
    f_title = get_font(20, custom_path=BAVEUSE_FONT)
    f_normal = get_font(14)
    
    draw.text((10, 5), "[H] mbcloud NAS", font=f_title, fill=COLOR_DATE)
    draw.text((10, 32), f"[NET] {get_ip()}", font=f_normal, fill=COLOR_TEXT)
    
    t = get_cpu_temp()
    tc = COLOR_TIME if t < 50 else COLOR_WARN if t < 70 else COLOR_ERROR
    draw.text((10, 55), f"[TMP] CPU: {t:.1f}C", font=f_normal, fill=tc)
    
    cpu = get_cpu_load()
    draw.text((DISPLAY_WIDTH//2, 55), f"[CPU] {cpu:.0f}%", font=f_normal, fill=COLOR_TEXT)
    
    bw = (DISPLAY_WIDTH - 30) // 2 - 5
    draw_progress(draw, 10, 75, bw, 14, cpu, (0, 200, 0), (50, 50, 50))
    draw_progress(draw, DISPLAY_WIDTH//2 + 5, 75, bw, 14, min(t, 100), tc, (50, 50, 50))
    
    ts = datetime.now().strftime("%H:%M:%S")
    f_big = get_font(30, custom_path=BAVEUSE_FONT)
    try:
        bbox = draw.textbbox((0, 0), ts, font=f_big)
        tx = (DISPLAY_WIDTH - bbox[2]) // 2
    except:
        tx = 70
        f_big = get_font(24)
    draw.text((tx, 105), ts, font=f_big, fill=COLOR_TIME)
    
    fs = "ON" if hasattr(fan, 'value') and fan.value > 0 else "OFF"
    draw.text((10, DISPLAY_HEIGHT - 25), f"[FAN] {fs}", font=f_normal, fill=(200, 200, 255))
    
    pp = ((current_page + 1) / TOTAL_PAGES) * 100
    draw_progress(draw, 0, DISPLAY_HEIGHT - 10, DISPLAY_WIDTH, 10, pp, (100, 100, 255), (30, 30, 30))
    
    return img

def draw_page_storage():
    """Страница 2: Диски"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), COLOR_BG)
    draw = ImageDraw.Draw(img)
    
    f_title = get_font(18, custom_path=BAVEUSE_FONT)
    f_normal = get_font(13)
    
    draw.text((10, 5), "[DSK] Storage", font=f_title, fill=COLOR_DATE)
    
    y = 32
    paths = [('/mnt/disk1', 'DISK1'), ('/mnt/disk2', 'DISK2'), ('/DATA', 'MERGER')]
    for p, name in paths:
        try:
            u = psutil.disk_usage(p)
            draw.text((10, y), f"{name}: {u.percent:.0f}%", font=f_normal, fill=COLOR_TEXT)
            draw_progress(draw, 10, y+14, DISPLAY_WIDTH - 20, 12, u.percent, (0, 200, 100), (40, 40, 40))
            y += 35
        except:
            pass
    
    return img

def draw_page_mergerfs():
    """Страница 3: MergerFS /DATA"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), COLOR_BG)
    draw = ImageDraw.Draw(img)
    
    f_title = get_font(20, custom_path=BAVEUSE_FONT)
    f_normal = get_font(14)
    
    draw.text((10, 5), "[VOL] /DATA", font=f_title, fill=COLOR_DATE)
    
    used, total, pct = get_disk_usage('/DATA')
    draw.text((10, 40), f"{used/1024:.2f} TB", font=f_title, fill=COLOR_TEXT)
    draw.text((10, 70), f"of {total/1024:.2f} TB", font=f_normal, fill=(150, 150, 150))
    
    bc = (0, 200, 0) if pct < 80 else COLOR_WARN if pct < 95 else COLOR_ERROR
    draw_progress(draw, 10, 95, DISPLAY_WIDTH - 20, 22, pct, bc, (50, 50, 50))
    draw.text((10, 125), f"{pct:.1f}% used", font=f_normal, fill=COLOR_TEXT)
    
    status = "[OK] Healthy" if pct < 95 else "[!] Almost full!"
    sc = COLOR_TIME if pct < 95 else COLOR_ERROR
    draw.text((10, 155), status, font=f_normal, fill=sc)
    
    return img

def draw_page_system():
    """Страница 4: Ресурсы"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), COLOR_BG)
    draw = ImageDraw.Draw(img)
    
    f_title = get_font(18, custom_path=BAVEUSE_FONT)
    f_normal = get_font(13)
    
    draw.text((10, 5), "[SYS] Resources", font=f_title, fill=COLOR_DATE)
    
    ru, rt, rp = get_ram()
    draw.text((10, 32), f"[RAM] {rp:.0f}% ({ru:.1f}/{rt:.1f}GB)", font=f_normal, fill=COLOR_TEXT)
    draw_progress(draw, 10, 48, DISPLAY_WIDTH - 20, 12, rp, (0, 150, 255), (40, 40, 40))
    
    cpu = get_cpu_load()
    draw.text((10, 70), f"[CPU] {cpu:.0f}%", font=f_normal, fill=COLOR_TEXT)
    draw_progress(draw, 10, 86, DISPLAY_WIDTH - 20, 12, cpu, (0, 200, 0), (40, 40, 40))
    
    draw.text((10, 110), f"[TMP] {get_cpu_temp():.1f}C | [UPTIME] {get_uptime()}", font=f_normal, fill=(200, 200, 255))
    
    return img

def draw_page_info():
    """Страница 5: Инфо"""
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), COLOR_BG)
    draw = ImageDraw.Draw(img)
    
    f_title = get_font(18, custom_path=BAVEUSE_FONT)
    f_normal = get_font(12)
    
    draw.text((10, 5), "[i] System Info", font=f_title, fill=COLOR_DATE)
    
    lines = [
        f"Debian 12 (Bookworm)",
        f"BCM2711 Quad-core A72",
        f"IP: {get_ip()}",
        f"Uptime: {get_uptime()}",
        f"Temperature: {get_cpu_temp():.1f}C",
        f"Display: 320x240 IPS",
        f"Docker: Active"
    ]
    
    y = 32
    for line in lines:
        draw.text((10, y), line, font=f_normal, fill=(200, 200, 255))
        y += 18
    
    return img

pages = [draw_page_dashboard, draw_page_storage, draw_page_mergerfs, draw_page_system, draw_page_info]

# ============================================================================
# 🎮 УПРАВЛЕНИЕ
# ============================================================================
display_on = True
current_page = 0
last_activity = time.time()

def update_display():
    """Обновить дисплей с поворотом"""
    global display_on, current_page
    
    img = draw_sleep_screen() if not display_on else pages[current_page]()
    
    # Поворот изображения
    if DISPLAY_ROTATION != 0:
        img = img.rotate(DISPLAY_ROTATION, expand=True)
    
    if DISPLAY_AVAILABLE:
        try:
            disp.ShowImage(img)
        except Exception as e:
            print(f"⚠️  Display error: {e}")
    else:
        status = "[Zzz]" if not display_on else f"[PG{current_page+1}]"
        print(f"{status} | Rot:{DISPLAY_ROTATION}° | {datetime.now().strftime('%H:%M:%S')}")

def next_page():
    """Следующая страница / пробуждение"""
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
    """Выключение системы"""
    print("🔌 Shutdown requested...")
    if DISPLAY_AVAILABLE:
        disp.clear()
    import os
    os.system("sudo shutdown -h now")

def control_fan():
    """Управление вентилятором"""
    t = get_cpu_temp()
    if t < FAN_TEMP_THRESHOLD:
        fan.value = 0
    else:
        fan.value = min(FAN_MAX_SPEED, 0.3 + (t - FAN_TEMP_THRESHOLD) * 0.05)

def check_sleep():
    """Проверка таймаута сна"""
    global display_on, last_activity
    while True:
        time.sleep(10)
        if display_on and (time.time() - last_activity) > SLEEP_TIMEOUT:
            display_on = False
            update_display()

# Обработчики кнопок
try:
    btn_user.when_pressed = next_page
    btn_pwr.when_pressed = toggle_display
    btn_pwr.when_held = shutdown_system
    btn_pwr.hold_time = 2
except:
    pass

# ============================================================================
# 🚀 ГЛАВНЫЙ ЦИКЛ
# ============================================================================
def main():
    print("🖥️  mbcloud Display Controller starting...")
    print(f"📁 Font path: {BAVEUSE_FONT} | Exists: {os.path.exists(BAVEUSE_FONT)}")
    
    threading.Thread(target=check_sleep, daemon=True).start()
    update_display()
    print(f"✅ Running. Pages: {TOTAL_PAGES}, Display: {'OK' if DISPLAY_AVAILABLE else 'Emulation'}")
    
    try:
        while True:
            control_fan()
            if not display_on:
                update_display()
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\n👋 Shutting down...")
        fan.value = 0
        if DISPLAY_AVAILABLE:
            disp.clear()

if __name__ == "__main__":
    main()
