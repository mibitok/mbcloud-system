# 🛠️ mbcloud NAS — Troubleshooting Guide

Решение распространённых проблем при установке и эксплуатации.

---

## 🚨 Быстрые решения

### ❌ Дисплей не показывает изображение

**Проверьте:**
1.  Настройки в `/boot/firmware/config.txt`:
    ```bash
    grep -E "spi|i2c" /boot/firmware/config.txt
    # Должно быть: dtparam=spi=on, dtparam=i2c_arm=on
    ```
2.  Устройства SPI:
    ```bash
    ls -l /dev/spidev*
    # Должно быть: /dev/spidev0.0
    ```
3.  Сервис дисплея:
    ```bash
    sudo systemctl status mbcloud-display.service
    sudo journalctl -u mbcloud-display.service -f
    ```

**Решение:**
```bash
# Если config.txt изменён — перезагрузите:
sudo reboot

# Если сервис упал — перезапустите:
sudo systemctl restart mbcloud-display.service
