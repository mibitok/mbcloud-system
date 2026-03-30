#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mbcloud NAS - LCD Display Controller
CM4-NAS-Double-Deck (Waveshare 2.4" IPS 240x240)
"""

import sys
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
DISPLAY_WIDTH = 240
DISPLAY_HEIGHT = 240
PIN_LCD_RST = 24
PIN_LCD_DC = 25
PIN_FAN_PWM = 18
PIN_BTN_PWR = 26   # Active LOW
PIN_BTN_USER = 20  # Active LOW
SLEEP_TIMEOUT = 60
FAN_TEMP_THRESHOLD = 45
FAN_MAX_SPEED = 0.8
TOTAL_PAGES = 5

# ============================================================================
# 🖥️ ИНИЦИАЛИЗАЦИЯ ДИСПЛЕЯ (исправлено)
# ============================================================================
DISPLAY_AVAILABLE = False
disp = None

# Добавляем путь к библиотеке Waveshare
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
except ImportError as e:
    print(f"⚠️  Waveshare driver not found: {e}")
    print(f"📥 Ensure demo is extracted to: {waveshare_path}")
except Exception as e:
    print(f"⚠️  Display init failed: {e}")

# Заглушка для эмуляции
if not DISPLAY_AVAILABLE:
    class DummyDisplay:
        def Init(self): pass
        def clear(self): pass
        def ShowImage(self, img): 
            # Печатаем в консоль для отладки
            print(f"🖼️  Display update: {img.size if img else 'None'}")
    disp = DummyDisplay()

# ============================================================================
# 💨 ВЕНТИЛЯТОР (исправленная частота)
# ============================================================================
try:
    fan = PWMOutputDevice(PIN_FAN_PWM, frequency=100)  # 100 Hz для стабильности
    fan.value = 0
    print("✅ Fan PWM initialized at 100Hz")
except Exception as e:
    print(f"⚠️  Fan init failed: {e}")
    class DummyFan:
        value = 0
    fan = DummyFan()

# ============================================================================
# 🔘 КНОПКИ (ОПРЕДЕЛЯЕМ ПЕРЕ ИСПОЛЬЗОВАНИЕМ!)
# ============================================================================
btn_user = Button(PIN_BTN_USER, pull_up=True, bounce_time=0.2)
btn_pwr = Button(PIN_BTN_PWR, pull_up=True, bounce_time=0.2)
print("✅ Buttons initialized")

# ============================================================================
# 📊 СИСТЕМНЫЕ ФУНКЦИИ (сокращённо - те же что были)
# ============================================================================
def get_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except: return "N/A"

def get_cpu_temp():
    try:
        with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
            return float(f.read()) / 1000
    except: return 0

def get_disk_usage(path):
    try:
        u = psutil.disk_usage(path)
        return u.used, u.total, u.percent
    except: return 0, 1, 0

def get_ram():
    m = psutil.virtual_memory()
    return m.used/(1024**3), m.total/(1024**3), m.percent

def get_cpu_load():
    return psutil.cpu_percent(interval=0.3)

def get_uptime():
    with open('/proc/uptime') as f:
        sec = float(f.read().split()[0])
    d, h, m = int(sec//86400), int((sec%86400)//3600), int((sec%3600)//60)
    return f"{d}d {h:02d}:{m:02d}"

def get_font(size=12):
    for path in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", None]:
        try:
            return ImageFont.truetype(path, size) if path else ImageFont.load_default()
        except: continue
    return ImageFont.load_default()

def draw_progress(draw, x, y, w, h, pct, fg, bg):
    draw.rectangle([x,y,x+w,y+h], fill=bg, outline=fg)
    fw = int(w * min(pct,100) / 100)
    if fw > 0: draw.rectangle([x,y,x+fw,y+h], fill=fg)

# ============================================================================
# 📄 СТРАНИЦЫ (упрощённые для надёжности)
# ============================================================================
def draw_page_dashboard():
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), (0,0,0))
    draw = ImageDraw.Draw(img)
    f1, f2 = get_font(16), get_font(13)
    draw.text((10,5), "🏠 mbcloud NAS", font=f1, fill=(0,255,255))
    draw.text((10,30), f"🌐 {get_ip()}", font=f2, fill=(255,255,255))
    t = get_cpu_temp()
    c = (0,255,0) if t<50 else (255,165,0) if t<70 else (255,0,0)
    draw.text((10,55), f"🌡️ CPU: {t:.1f}°C", font=f2, fill=c)
    cpu = get_cpu_load()
    draw.text((10,80), f"⚡ Load: {cpu:.0f}%", font=f2, fill=(255,255,255))
    draw_progress(draw, 10, 95, 220, 12, cpu, (0,200,0), (50,50,50))
    draw.text((10,115), f"🕐 {datetime.now().strftime('%H:%M:%S')}", font=f2, fill=(255,255,0))
    return img

def draw_page_storage():
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), (0,0,0))
    draw = ImageDraw.Draw(img)
    f = get_font(14)
    draw.text((10,5), "💾 Disks", font=f, fill=(0,255,255))
    y = 30
    for p in ['/mnt/disk1', '/mnt/disk2', '/DATA']:
        try:
            u = psutil.disk_usage(p)
            name = p.split('/')[-1]
            draw.text((10,y), f"{name}: {u.percent:.0f}%", font=get_font(11), fill=(255,255,255))
            draw_progress(draw, 10, y+12, 220, 10, u.percent, (0,200,100), (40,40,40))
            y += 30
        except: pass
    return img

def draw_page_mergerfs():
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), (0,0,0))
    draw = ImageDraw.Draw(img)
    f = get_font(16)
    draw.text((10,5), "🗄️ /DATA", font=f, fill=(0,255,255))
    used, total, pct = get_disk_usage('/DATA')
    draw.text((10,40), f"{used/1024:.1f} TB", font=f, fill=(255,255,255))
    draw.text((10,65), f"of {total/1024:.1f} TB", font=get_font(13), fill=(150,150,150))
    draw_progress(draw, 10, 90, 220, 20, pct, (0,200,0) if pct<80 else (255,100,0), (50,50,50))
    draw.text((10,120), f"{pct:.1f}% used", font=get_font(13), fill=(255,255,255))
    return img

def draw_page_system():
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), (0,0,0))
    draw = ImageDraw.Draw(img)
    f = get_font(13)
    draw.text((10,5), "⚙️ Resources", font=get_font(14), fill=(0,255,255))
    ru, rt, rp = get_ram()
    draw.text((10,30), f"🧠 RAM: {rp:.0f}% ({ru:.1f}/{rt:.1f}GB)", font=f, fill=(255,255,255))
    draw_progress(draw, 10, 45, 220, 10, rp, (0,150,255), (40,40,40))
    cpu = get_cpu_load()
    draw.text((10,65), f"⚡ CPU: {cpu:.0f}%", font=f, fill=(255,255,255))
    draw_progress(draw, 10, 80, 220, 10, cpu, (0,200,0), (40,40,40))
    draw.text((10,100), f"🌡️ {get_cpu_temp():.1f}°C | ⏱️ {get_uptime()}", font=f, fill=(200,200,255))
    return img

def draw_page_info():
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), (0,0,0))
    draw = ImageDraw.Draw(img)
    f = get_font(11)
    draw.text((10,5), "ℹ️ Info", font=get_font(14), fill=(0,255,255))
    lines = [f"Debian 12", f"BCM2711", f"IP: {get_ip()}", f"Uptime: {get_uptime()}", f"Temp: {get_cpu_temp():.1f}°C"]
    for i, line in enumerate(lines):
        draw.text((10, 30 + i*18), line, font=f, fill=(200,200,255))
    return img

def draw_sleep_screen():
    img = Image.new('RGB', (DISPLAY_WIDTH, DISPLAY_HEIGHT), (0,0,0))
    draw = ImageDraw.Draw(img)
    ft, fd = get_font(32), get_font(14)
    # Простые "звёзды"
    for i in range(15):
        draw.point(((i*17)%240, (i*23)%240), fill=(150,150,255))
    ts = datetime.now().strftime("%H:%M")
    ds = datetime.now().strftime("%a %d.%m")
    draw.text((60, 70), ts, font=ft, fill=(0,255,255))
    draw.text((10, 140), ds, font=fd, fill=(150,150,255))
    return img

pages = [draw_page_dashboard, draw_page_storage, draw_page_mergerfs, draw_page_system, draw_page_info]

# ============================================================================
# 🎮 УПРАВЛЕНИЕ (ОБРАБОТЧИКИ ПОСЛЕ ИНИЦИАЛИЗАЦИИ КНОПОК!)
# ============================================================================
display_on = True
current_page = 0
last_activity = time.time()

def update_display():
    global display_on, current_page
    img = draw_sleep_screen() if not display_on else pages[current_page]()
    if DISPLAY_AVAILABLE:
        try: disp.ShowImage(img)
        except Exception as e: print(f"⚠️ Display error: {e}")
    else:
        print(f"🖼️  Page {current_page+1}/5 | Sleep: {not display_on}")

def next_page():
    global display_on, current_page, last_activity
    last_activity = time.time()
    if not display_on: display_on = True
    else: current_page = (current_page + 1) % TOTAL_PAGES
    update_display()

def toggle_display():
    global display_on, last_activity
    display_on = not display_on
    last_activity = time.time()
    update_display()

def shutdown_system():
    print("🔌 Shutdown requested...")
    if DISPLAY_AVAILABLE: disp.clear()
    import os
    os.system("sudo shutdown -h now")

def control_fan():
    t = get_cpu_temp()
    if t < FAN_TEMP_THRESHOLD: fan.value = 0
    else: fan.value = min(FAN_MAX_SPEED, 0.3 + (t - FAN_TEMP_THRESHOLD) * 0.05)

def check_sleep():
    global display_on, last_activity
    while True:
        time.sleep(10)
        if display_on and (time.time() - last_activity) > SLEEP_TIMEOUT:
            display_on = False
            update_display()

# === Назначаем обработчики ПОСЛЕ создания кнопок ===
btn_user.when_pressed = next_page
btn_pwr.when_pressed = toggle_display
btn_pwr.when_held = shutdown_system
btn_pwr.hold_time = 2

# ============================================================================
# 🚀 ГЛАВНЫЙ ЦИКЛ
# ============================================================================
def main():
    print("🖥️  mbcloud Display Controller starting...")
    threading.Thread(target=check_sleep, daemon=True).start()
    update_display()
    print(f"✅ Running. Pages: {TOTAL_PAGES}, Display: {'OK' if DISPLAY_AVAILABLE else 'Emulation'}")
    
    try:
        while True:
            control_fan()
            if not display_on: update_display()  # Обновляем время в сне
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\n👋 Shutting down...")
        fan.value = 0
        if DISPLAY_AVAILABLE: disp.clear()

if __name__ == "__main__":
    main()
