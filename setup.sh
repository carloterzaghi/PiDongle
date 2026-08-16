#!/bin/bash
# Setup script - executar no Raspberry Pi Zero 2 W como root
# sudo bash setup.sh

set -e

echo "=== rasp-desk setup ==="

# --- Dependências ---
apt-get update -y
apt-get install -y python3 python3-pip python3-venv dnsmasq git tcpdump

# --- Detectar caminho de boot (Bookworm/Trixie usa /boot/firmware) ---
if [ -d /boot/firmware ]; then
    BOOT=/boot/firmware
else
    BOOT=/boot
fi
CONFIG="$BOOT/config.txt"
CMDLINE="$BOOT/cmdline.txt"
echo "[boot] usando $BOOT"

# --- Habilitar USB gadget (dwc2 + g_ether) ---
if ! grep -q "dtoverlay=dwc2" "$CONFIG"; then
    echo "dtoverlay=dwc2" >> "$CONFIG"
    echo "[config.txt] dtoverlay=dwc2 adicionado"
else
    echo "[config.txt] dtoverlay=dwc2 já presente"
fi

# Remove entradas antigas duplicadas de g_ether ou libcomposite
sed -i 's/ modules-load=dwc2,g_ether//g; s/ modules-load=dwc2,libcomposite//g' "$CMDLINE"

# Adiciona libcomposite (RNDIS — compatível com Windows)
if grep -q "rootwait" "$CMDLINE"; then
    sed -i 's/rootwait/modules-load=dwc2,libcomposite rootwait/' "$CMDLINE"
else
    sed -i 's/$/ modules-load=dwc2,libcomposite/' "$CMDLINE"
fi
echo "[cmdline.txt] módulos USB configurados: dwc2,libcomposite"

# --- Script do gadget RNDIS com MS OS Descriptors (Windows auto-detecta) ---
cat > /usr/local/bin/usb-gadget.sh <<'GADGET'
#!/bin/bash
# RNDIS com MS OS Descriptors: compatível com Windows (todas as versões)
modprobe libcomposite
modprobe usb_f_rndis 2>/dev/null || true

G=/sys/kernel/config/usb_gadget/pi

# Desmonta gadget anterior completamente antes de reconfigurar
if [ -d "$G" ]; then
    echo "" > "$G/UDC" 2>/dev/null || true
    rm -f "$G/os_desc/c.1"               2>/dev/null || true
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

# --- RNDIS function ---
mkdir -p functions/rndis.usb0
echo "DE:AD:BE:EF:00:01" > functions/rndis.usb0/host_addr
echo "DE:AD:BE:EF:00:02" > functions/rndis.usb0/dev_addr

# --- MS OS Descriptors (Windows reconhece automaticamente como adaptador de rede) ---
echo 1       > os_desc/use
echo 0xcd    > os_desc/b_vendor_code
echo MSFT100 > os_desc/qw_sign

mkdir -p functions/rndis.usb0/os_desc/interface.rndis
echo RNDIS   > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
echo 5162001 > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id

mkdir -p configs/c.1/strings/0x409
echo "RNDIS Network" > configs/c.1/strings/0x409/configuration
echo 250             > configs/c.1/MaxPower

ln -s "$G/functions/rndis.usb0" "$G/configs/c.1/"
ln -s "$G/configs/c.1"          "$G/os_desc/"

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
echo "[gadget] script RNDIS criado"

# --- Serviço systemd para iniciar o gadget no boot ---
cat > /etc/systemd/system/usb-gadget.service <<'EOF'
[Unit]
Description=USB RNDIS Gadget
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
echo "[gadget] serviço habilitado"

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
echo "[network] usb0 configurado via systemd-networkd: 10.55.55.1"

# --- dnsmasq: DHCP para o host via USB ---
DNSMASQ_CONF=/etc/dnsmasq.d/usb0.conf
cat > "$DNSMASQ_CONF" <<'EOF'
interface=usb0
bind-interfaces
dhcp-range=10.55.55.10,10.55.55.20,24h
dhcp-option=3
dhcp-option=6
EOF
echo "[dnsmasq] DHCP configurado para usb0"

# Garantir que dnsmasq inicie após o gadget USB estar pronto
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/wait-usb.conf <<'EOF'
[Unit]
After=usb-gadget.service
Wants=usb-gadget.service
EOF
echo "[dnsmasq] dependência no usb-gadget adicionada"

systemctl enable dnsmasq
systemctl restart dnsmasq

# --- Instalar app ---
APP_DIR=/opt/rasp-desk
mkdir -p "$APP_DIR"
cp -r app "$APP_DIR/"
cp -r scripts "$APP_DIR/"
chmod +x "$APP_DIR/scripts/"*.sh 2>/dev/null || true

cd "$APP_DIR/app"
python3 -m venv venv
venv/bin/pip install --upgrade pip
venv/bin/pip install flask psutil

# --- Systemd service ---
cat > /etc/systemd/system/rasp-desk.service <<EOF
[Unit]
Description=rasp-desk web control panel
After=network.target usb-gadget.service
Wants=usb-gadget.service

[Service]
ExecStart=/opt/rasp-desk/app/venv/bin/python /opt/rasp-desk/app/app.py
WorkingDirectory=/opt/rasp-desk/app
Restart=always
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable rasp-desk
systemctl restart rasp-desk

echo ""
echo "=== Setup concluído! ==="
echo "Após reiniciar, acesse: http://10.55.55.1:5000"
echo "Reiniciando em 5 segundos..."
sleep 5
reboot
