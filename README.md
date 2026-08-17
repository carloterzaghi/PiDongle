# PiDongle

Web control panel for Raspberry Pi Zero 2 W via USB Ethernet.

## How to use

### 1. Copy to the Pi

With the Pi already powered on and accessible (SSH or SD card on the PC):

```bash
scp -r PiDongle/ pi@raspberrypi.local:~/
```

### 2. Run setup on the Pi

```bash
ssh pi@raspberrypi.local
cd ~/PiDongle
sudo bash setup.sh
```

The script will:
- Enable the USB gadget (`dwc2` + `CDC NCM`)
- Configure the static IP `10.55.55.1` on the `usb0` interface
- Install `dnsmasq` to serve DHCP to the PC
- Install Flask and start the panel as a service
- Restart the Pi automatically

### 3. Connect via USB

Plug the USB cable into the **USB** port of the Pi Zero (not PWR).  
The PC will automatically receive an IP in the `10.55.55.10–20` range.

> The USB gadget uses **CDC NCM** (Network Control Model) — a modern USB standard recognized natively by **Windows 10+, Linux and macOS**, without manually installing any drivers.

### 4. Open the panel

```
http://10.55.55.1:5000
```

---

## Structure

```
PiDongle/
├── setup.sh                # Complete setup (run on the Pi)
├── app/
│   ├── app.py              # Flask server
│   ├── requirements.txt
│   └── templates/
│       └── index.html      # Web interface
├── scripts/                # Scripts executed by actions
│   ├── reboot.sh
│   ├── shutdown.sh
│   ├── update.sh
│   ├── temp.sh
│   ├── blink.sh
│   └── custom.sh           # ← add your scripts here
```

## Add new actions

1. Create a script in `scripts/my_action.sh`
2. Add an entry in the `ACTIONS` dictionary in `app/app.py`:
   ```python
   "my_action": {"label": "My Action", "icon": "🚀", "confirm": False, "script": "my_action.sh"},
   ```
3. Restart the service: `sudo systemctl restart PiDongle`

## Troubleshooting

### Cannot access http://10.55.55.1:5000

1. Check if the PC received an IP in the `10.55.55.10–20` range (via `ipconfig`)
2. Verify if the services are running on the Pi:
   ```bash
   sudo systemctl status usb-gadget PiDongle dnsmasq
   ```

## Security notes

- The panel runs only on the `usb0` interface (USB local network) — it is not exposed to the internet.
- Only scripts listed in `ACTIONS` can be executed (whitelist).
- The server has no authentication; add it if the Pi is accessible on other networks.
