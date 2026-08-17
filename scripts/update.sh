#!/bin/bash
# update.sh — Updates the OS and the PiDongle app

set -e

# --- 1. System update ---
echo "=== [1/3] Updating system packages ==="
apt-get update -y
echo "Fixing any broken dependencies..."
apt-get --fix-broken install -y
apt-get upgrade -y
echo "System updated successfully."

# --- 2. Update PiDongle app ---
echo ""
echo "=== [2/3] Updating PiDongle app ==="

# Detect install dir and source dir
INSTALL_DIR=/opt/PiDongle
SERVICE=PiDongle

# Derive source from the script's own location (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
SOURCE_DIR="$(dirname "$SCRIPT_DIR")"

# Fallback: scan common locations if app/ not found under derived dir
if [ ! -d "$SOURCE_DIR/app" ]; then
    for SRC in ~/PiDongle ~/pidongle /home/pi/PiDongle /home/pi/pidongle; do
        if [ -d "$SRC" ]; then
            SOURCE_DIR="$SRC"
            break
        fi
    done
fi

if [ ! -d "$SOURCE_DIR/app" ]; then
    echo "WARNING: No PiDongle source directory found. Skipping app update."
elif [ "$(realpath "$SOURCE_DIR")" = "$(realpath "$INSTALL_DIR")" ]; then
    echo "Already running from $INSTALL_DIR; nothing to copy."
    echo "Use deploy.sh from your PC to push new app files."
else
    echo "Source: $SOURCE_DIR → $INSTALL_DIR"
    cp -r "$SOURCE_DIR/app"     "$INSTALL_DIR/"
    cp -r "$SOURCE_DIR/scripts" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/scripts/"*.sh 2>/dev/null || true
    echo "App files updated."
fi

# --- 3. Restart service ---
echo ""
echo "=== [3/3] Restarting PiDongle service ==="
systemctl restart "$SERVICE"
echo "Service restarted successfully."
echo ""
echo "=== Update complete! Panel: http://10.55.55.1:5000 ==="
