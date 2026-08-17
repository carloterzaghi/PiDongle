#!/bin/bash
# wifi.sh — Lista e conecta a redes Wi-Fi via NetworkManager (nmcli)
# Uso: bash wifi.sh scan | current | connect <ssid> [senha]

IFACE=wlan0
ACTION="${1:-scan}"

require_nmcli() {
    command -v nmcli >/dev/null 2>&1 || { echo "ERROR: nmcli not found (NetworkManager required)"; exit 1; }
}

scan_networks() {
    require_nmcli
    # --rescan yes faz nmcli aguardar o scan terminar antes de listar
    nmcli -t -f SSID,SIGNAL,SECURITY,ACTIVE device wifi list ifname "$IFACE" --rescan yes 2>/dev/null |
        awk -F: '$1 != "" {print}' |
        sort -t: -k2 -nr -u
}

current_network() {
    require_nmcli
    nmcli -t -f ACTIVE,SSID device wifi list ifname "$IFACE" | awk -F: '$1=="yes"{print $2; exit}'
}

connect_network() {
    require_nmcli
    SSID="$2"
    PASS="$3"
    [ -z "$SSID" ] && { echo "ERROR: SSID is required"; exit 1; }

    if [ -n "$PASS" ]; then
        nmcli device wifi connect "$SSID" password "$PASS" ifname "$IFACE"
    else
        nmcli device wifi connect "$SSID" ifname "$IFACE"
    fi
}

case "$ACTION" in
    scan)    scan_networks ;;
    current) current_network ;;
    connect) connect_network "$@" ;;
    *)       echo "Usage: $0 {scan|current|connect <ssid> [password]}"; exit 1 ;;
esac
