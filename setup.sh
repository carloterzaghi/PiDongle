#!/bin/bash
# Setup script - executar no Raspberry Pi Zero 2 W como root
# sudo bash setup.sh

set -e

echo "=== PiDongle setup ==="

# --- Dependências ---
apt-get update -y
apt-get install -y python3 python3-pip python3-venv dnsmasq git tcpdump iptables samba

# --- Detectar caminho de boot (Bookworm/Trixie usa /boot/firmware) ---
if [ -d /boot/firmware ]; then
    BOOT=/boot/firmware
else
    BOOT=/boot
fi
CONFIG="$BOOT/config.txt"
CMDLINE="$BOOT/cmdline.txt"
echo "[boot] using $BOOT"

# --- Habilitar USB gadget (dwc2 + CDC NCM) ---
if ! grep -q "dtoverlay=dwc2" "$CONFIG"; then
    echo "dtoverlay=dwc2" >> "$CONFIG"
    echo "[config.txt] dtoverlay=dwc2 added"
else
    echo "[config.txt] dtoverlay=dwc2 already present"
fi

# Remove entradas antigas duplicadas de g_ether, libcomposite ou g_ncm
sed -i 's/ modules-load=dwc2,g_ether//g; s/ modules-load=dwc2,libcomposite//g; s/ modules-load=dwc2,g_ncm//g' "$CMDLINE"

# Adiciona libcomposite (CDC NCM — compatível com todos os SOs modernos)
if grep -q "rootwait" "$CMDLINE"; then
    sed -i 's/rootwait/modules-load=dwc2,libcomposite rootwait/' "$CMDLINE"
else
    sed -i 's/$/ modules-load=dwc2,libcomposite/' "$CMDLINE"
fi
echo "[cmdline.txt] USB modules configured: dwc2,libcomposite"

# --- Script do gadget CDC NCM (plug-and-play em Windows 10+, Linux e macOS) ---
cat > /usr/local/bin/usb-gadget.sh <<'GADGET'
#!/bin/bash
# CDC NCM: padrão USB moderno, reconhecido nativamente por todos os SOs
modprobe libcomposite
modprobe usb_f_ncm 2>/dev/null || true

G=/sys/kernel/config/usb_gadget/pi

# Desmonta gadget anterior completamente antes de reconfigurar
if [ -d "$G" ]; then
    echo "" > "$G/UDC" 2>/dev/null || true
    rm -f "$G/configs/c.1/ncm.usb0"      2>/dev/null || true
    rm -f "$G/configs/c.1/rndis.usb0"    2>/dev/null || true
    rmdir "$G/configs/c.1/strings/0x409" 2>/dev/null || true
    rmdir "$G/configs/c.1"               2>/dev/null || true
    rmdir "$G/functions/ncm.usb0"        2>/dev/null || true
    rmdir "$G/functions/rndis.usb0"      2>/dev/null || true
    rmdir "$G/strings/0x409"             2>/dev/null || true
    rmdir "$G"                           2>/dev/null || true
fi

mkdir -p "$G" && cd "$G"

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "raspberrypi0001" > strings/0x409/serialnumber
echo "Raspberry Pi"    > strings/0x409/manufacturer
echo "Pi USB Gadget"   > strings/0x409/product

# --- CDC NCM function ---
mkdir -p functions/ncm.usb0
echo "DE:AD:BE:EF:00:01" > functions/ncm.usb0/host_addr
echo "DE:AD:BE:EF:00:02" > functions/ncm.usb0/dev_addr

mkdir -p configs/c.1/strings/0x409
echo "CDC NCM Network" > configs/c.1/strings/0x409/configuration
echo 250               > configs/c.1/MaxPower

ln -s "$G/functions/ncm.usb0" "$G/configs/c.1/"

# Ativar gadget
ls /sys/class/udc > UDC

# Esperar a interface usb0 aparecer (até 30 segundos)
for i in $(seq 1 30); do
    ip link show usb0 > /dev/null 2>&1 && break
    sleep 1
done

# Levantar interface (IP gerenciado por systemd-networkd)
ip link set usb0 up
GADGET
chmod +x /usr/local/bin/usb-gadget.sh
echo "[gadget] CDC NCM script created"

# --- Serviço systemd para iniciar o gadget no boot ---
cat > /etc/systemd/system/usb-gadget.service <<'EOF'
[Unit]
Description=USB CDC NCM Gadget
After=sysinit.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/usb-gadget.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable usb-gadget
echo "[gadget] service enabled"

# --- Interface usb0 com IP fixo (systemd-networkd) ---
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/usb0.network <<'EOF'
[Match]
Name=usb0

[Network]
Address=10.55.55.1/24
EOF
systemctl enable systemd-networkd
systemctl restart systemd-networkd
echo "[network] usb0 configured via systemd-networkd: 10.55.55.1"

# --- dnsmasq: DHCP para o host via USB ---
DNSMASQ_CONF=/etc/dnsmasq.d/usb0.conf
cat > "$DNSMASQ_CONF" <<'EOF'
interface=usb0
bind-interfaces
dhcp-range=10.55.55.10,10.55.55.20,24h
dhcp-option=3
dhcp-option=6
EOF
echo "[dnsmasq] DHCP configured for usb0"

# Garantir que dnsmasq inicie após o gadget USB estar pronto
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/wait-usb.conf <<'EOF'
[Unit]
After=usb-gadget.service
Wants=usb-gadget.service
EOF
echo "[dnsmasq] dependency on usb-gadget added"

systemctl enable dnsmasq
systemctl restart dnsmasq

# --- Install app ---
APP_DIR=/opt/PiDongle
mkdir -p "$APP_DIR"
cp -r app "$APP_DIR/"
cp -r scripts "$APP_DIR/"
chmod +x "$APP_DIR/scripts/"*.sh 2>/dev/null || true

cd "$APP_DIR/app"
python3 -m venv venv
venv/bin/pip install --upgrade pip
venv/bin/pip install flask psutil ptyprocess

# --- Install Node.js, OmniRoute & PM2 ---
echo "[setup] Installing Node.js v22..."
curl -fsSL https://deb.nodesource.com/setup_22.x -o nodesource_setup.sh
bash nodesource_setup.sh
apt-get install -y nodejs
rm -f nodesource_setup.sh

echo "[setup] Creating temporary 2GB swap for npm install..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

echo "[setup] Installing 9Router, PM2, and Claude Code (this should be fast!)..."
npm install -g 9router pm2 @anthropic-ai/claude-code

echo "[setup] Removing temporary swap..."
swapoff /swapfile
rm -f /swapfile


# --- Systemd service ---
cat > /etc/systemd/system/PiDongle.service <<EOF
[Unit]
Description=PiDongle web control panel
After=network.target usb-gadget.service
Wants=usb-gadget.service

[Service]
ExecStart=/opt/PiDongle/app/venv/bin/python /opt/PiDongle/app/app.py
WorkingDirectory=/opt/PiDongle/app
Restart=always
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable PiDongle
systemctl restart PiDongle

echo ""
echo "=== Setup completed! ==="
echo "After reboot, access: http://10.55.55.1:5000"
echo "Rebooting in 5 seconds..."
sleep 5
reboot
