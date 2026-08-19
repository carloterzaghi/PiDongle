#!/bin/bash
# storage.sh — Configure and start 20GB Samba Share
# This script is called from the web UI.

IMG_PATH="/opt/PiDongle/storage.img"
MOUNT_DIR="/opt/PiDongle/Storage"
SMB_CONF="/etc/samba/smb.conf"

echo "Setting up Storage (20 GB)..."

# 1. Create 20GB sparse file if it doesn't exist
if [ ! -f "$IMG_PATH" ]; then
    echo "Creating 20GB storage file (this may take a moment)..."
    truncate -s 20G "$IMG_PATH"
    echo "Formatting as ext4..."
    mkfs.ext4 -F "$IMG_PATH"
fi

# 2. Create mount point
mkdir -p "$MOUNT_DIR"

# 3. Check if already mounted, if not, mount it
if ! mountpoint -q "$MOUNT_DIR"; then
    echo "Mounting storage..."
    mount -o loop "$IMG_PATH" "$MOUNT_DIR"
    chmod 777 "$MOUNT_DIR"
fi

# 4. Add to fstab if not present (so it survives reboots)
if ! grep -q "$IMG_PATH" /etc/fstab; then
    echo "$IMG_PATH $MOUNT_DIR ext4 loop,defaults 0 0" >> /etc/fstab
fi

# 5. Configure Samba
if ! command -v smbd >/dev/null 2>&1; then
    echo "Erro: Samba (compartilhamento de rede) não está instalado!"
    echo "Por favor, instale usando: sudo apt-get install -y samba"
    exit 1
fi

if ! grep -q "\[PiDongleStorage\]" "$SMB_CONF"; then
    echo "Configuring Samba share..."
    cat >> "$SMB_CONF" <<EOF

[PiDongleStorage]
   path = $MOUNT_DIR
   browseable = yes
   read only = no
   guest ok = yes
   force user = root
EOF
    systemctl restart smbd
    echo "Samba share configured and started!"
else
    echo "Samba share is already configured."
    systemctl reload smbd
fi

echo ""
echo "Storage is ready! Access it on Windows via: \\\\10.55.55.1\\PiDongleStorage"
