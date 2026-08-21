#!/bin/bash
# share_wifi.sh — Ativa/desativa compartilhamento de internet Wi-Fi → USB
# Uso: bash share_wifi.sh on|off|status

WLAN=wlan0
USB=usb0
ACTION="${1:-status}"

SYSCTL_CONF=/etc/sysctl.d/99-pidongle-forward.conf
IPTABLES_RULES=/etc/iptables.pidongle.rules

enable_sharing() {
    # 0a. Garantir que usb0 existe e tem o IP correto
    if ! ip link show "$USB" &>/dev/null; then
        echo "ERROR: Interface $USB does not exist. Is USB gadget active?"
        exit 1
    fi
    if ! ip addr show "$USB" 2>/dev/null | grep -q "10.55.55.1"; then
        ip addr flush dev "$USB" 2>/dev/null
        ip addr add 10.55.55.1/24 dev "$USB" 2>/dev/null || true
        ip link set "$USB" up
    fi

    # 0b. Verificar se wlan0 tem conectividade real (rota default)
    if ! ip route show default dev "$WLAN" 2>/dev/null | grep -q default; then
        echo "ERROR: $WLAN has no default route. Is Wi-Fi connected?"
        exit 1
    fi

    # 1. Ativar IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward
    # Persistir para sobreviver a reboots (drop-in próprio, não depende de /etc/sysctl.conf existir)
    echo "net.ipv4.ip_forward=1" > "$SYSCTL_CONF"

    # 2. Regra de NAT (masquerade) — saída pela wlan0
    iptables -t nat -C POSTROUTING -o "$WLAN" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$WLAN" -j MASQUERADE

    # 3. Permitir tráfego de encaminhamento
    iptables -C FORWARD -i "$USB" -o "$WLAN" -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$USB" -o "$WLAN" -j ACCEPT
    iptables -C FORWARD -i "$WLAN" -o "$USB" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -i "$WLAN" -o "$USB" -m state --state RELATED,ESTABLISHED -j ACCEPT

    # 3b. Persistir regras iptables para sobreviver a reboots
    iptables-save > "$IPTABLES_RULES"

    # 4. Atualizar dnsmasq para enviar gateway e DNS ao PC
    DNSMASQ_CONF=/etc/dnsmasq.d/usb0.conf
    cat > "$DNSMASQ_CONF" <<'EOF'
interface=usb0
bind-interfaces
dhcp-range=10.55.55.10,10.55.55.20,24h
dhcp-option=3,10.55.55.1
dhcp-option=6,8.8.8.8,8.8.4.4
EOF
    systemctl restart dnsmasq

    # 4b. Aguardar dnsmasq estar escutando na porta 67 (DHCP)
    for i in $(seq 1 10); do
        ss -ulnp 2>/dev/null | grep -q ':67 ' && break
        sleep 0.5
    done

    # 5. Criar marcador de estado
    touch /tmp/pidongle_sharing_active

    echo "Internet sharing ENABLED (Wi-Fi → USB)"
    echo "Gateway: 10.55.55.1 | DNS: 8.8.8.8, 8.8.4.4"
    echo "NOTE: Reconnect the USB cable or run 'ipconfig /renew' on the PC to get the new settings."
}

disable_sharing() {
    # 1. Remover regras de NAT e forwarding
    iptables -t nat -D POSTROUTING -o "$WLAN" -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i "$USB" -o "$WLAN" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$WLAN" -o "$USB" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    # 2. Desativar IP forwarding
    echo 0 > /proc/sys/net/ipv4/ip_forward
    rm -f "$SYSCTL_CONF"

    # 3. Remover regras iptables persistidas
    rm -f "$IPTABLES_RULES"

    # 4. Restaurar dnsmasq para modo local (sem gateway/DNS)
    DNSMASQ_CONF=/etc/dnsmasq.d/usb0.conf
    cat > "$DNSMASQ_CONF" <<'EOF'
interface=usb0
bind-interfaces
dhcp-range=10.55.55.10,10.55.55.20,24h
dhcp-option=3
dhcp-option=6
EOF
    systemctl restart dnsmasq

    # 5. Remover marcador
    rm -f /tmp/pidongle_sharing_active

    echo "Internet sharing DISABLED"
    echo "USB connection is now local-only again."
}

check_status() {
    if [ -f /tmp/pidongle_sharing_active ] && iptables -t nat -C POSTROUTING -o "$WLAN" -j MASQUERADE 2>/dev/null; then
        echo "active"
    else
        # Verificar se há regras persistidas do boot anterior (estado orfão)
        if [ -f "$IPTABLES_RULES" ] && iptables -t nat -C POSTROUTING -o "$WLAN" -j MASQUERADE 2>/dev/null; then
            # Regras estão ativas mas marcador sumiu (pós-reboot) — re-criar marcador
            touch /tmp/pidongle_sharing_active
            echo "active"
        else
            rm -f /tmp/pidongle_sharing_active
            echo "inactive"
        fi
    fi
}

case "$ACTION" in
    on)     enable_sharing ;;
    off)    disable_sharing ;;
    status) check_status ;;
    *)      echo "Usage: $0 {on|off|status}"; exit 1 ;;
esac
