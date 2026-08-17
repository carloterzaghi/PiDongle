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
        sort -t: -k2 -nr |
        awk -F: '!seen[$1]++'
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
        OUTPUT=$(nmcli device wifi connect "$SSID" password "$PASS" ifname "$IFACE" 2>&1)
        RET=$?
        if [ $RET -ne 0 ] && echo "$OUTPUT" | grep -q "key-mgmt"; then
            # Tenta forçar a criação do perfil com WPA-PSK
            nmcli connection delete "$SSID" >/dev/null 2>&1
            nmcli connection add type wifi ifname "$IFACE" con-name "$SSID" ssid "$SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASS" >/dev/null 2>&1
            OUTPUT_UP=$(nmcli connection up "$SSID" 2>&1)
            if [ $? -eq 0 ]; then
                echo "$OUTPUT_UP"
            else
                echo "Erro: $OUTPUT_UP (Fallback failed)"
                exit 1
            fi
        elif [ $RET -ne 0 ]; then
            echo "$OUTPUT"
            exit $RET
        else
            echo "$OUTPUT"
        fi
    else
        OUTPUT=$(nmcli device wifi connect "$SSID" ifname "$IFACE" 2>&1)
        RET=$?
        if [ $RET -ne 0 ] && echo "$OUTPUT" | grep -q "key-mgmt"; then
            echo "Erro: Esta rede precisa de senha. Deixá-la em branco só funciona se a rede já estiver salva."
            exit 1
        elif [ $RET -ne 0 ]; then
            echo "$OUTPUT"
            exit $RET
        else
            echo "$OUTPUT"
        fi
    fi
}

case "$ACTION" in
    scan)    scan_networks ;;
    current) current_network ;;
    connect) connect_network "$@" ;;
    *)       echo "Usage: $0 {scan|current|connect <ssid> [password]}"; exit 1 ;;
esac
