#!/bin/bash

set -euo pipefail

# Default values. The interactive setup wizard can override these at runtime.
BR_IFACE="br0"
WAN_IFACE="eth0"
LAN_IFACE="eth1"
WIFI_IFACE="wlan0"
TARGET_LINK_MODE="wifi"

WIFI_SSID="iOTsec"
WIFI_PASSWORD="Hom3rHom3r"
WIFI_COUNTRY_CODE="US"
WIFI_CHANNEL="11"

LAN_IP="192.168.200.1"
LAN_SUBNET="255.255.255.0"
LAN_CIDR="24"
LAN_DHCP_START="192.168.200.10"
LAN_DHCP_END="192.168.200.100"
LAN_DNS_SERVER="1.1.1.1"
LAN_DHCP_LEASE="12h"

DNSMASQ_CONF="tmp_dnsmasq.conf"
HOSTAPD_CONF="tmp_hostapd.conf"
SERVICE_STATE_FILE="tmp_service_state"
ROUTER_STATE_FILE="tmp_router_state"
SESSION_CONFIG_FILE="tmp_session_config"

SYSTEMCTL=$(command -v systemctl || true)
SERVICE_CMD=$(command -v service || true)
NMCLI=$(command -v nmcli || true)
ROUTER_ACTIVE=0

usage() {
    cat <<EOF
Usage: $0 <up|down>

Commands:
  up    Start the MITM router setup. You will be guided through the network settings.
  down  Stop the MITM router setup and restore service state.
EOF
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_header() {
    printf "\n== %s\n" "$1"
}

die() {
    printf "Error: %s\n" "$1" >&2
    exit 1
}

list_candidate_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' || true
}

show_interface_overview() {
    print_header "Available interfaces"
    ip -brief addr show || true
}

is_valid_interface() {
    local iface=$1
    [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1
}

validate_ip() {
    local ip=$1
    local IFS=.
    local -a octets

    read -r -a octets <<< "$ip"
    [ "${#octets[@]}" -eq 4 ] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
    done
}

validate_cidr() {
    local cidr=$1
    [[ "$cidr" =~ ^[0-9]+$ ]] || return 1
    [ "$cidr" -ge 1 ] && [ "$cidr" -le 32 ]
}

cidr_to_netmask() {
    local cidr=$1
    local mask=""
    local full_octets=$((cidr / 8))
    local partial_octet=$((cidr % 8))
    local octet_value
    local i

    for i in 1 2 3 4; do
        if [ "$i" -le "$full_octets" ]; then
            octet_value=255
        elif [ "$i" -eq $((full_octets + 1)) ] && [ "$partial_octet" -gt 0 ]; then
            octet_value=$((256 - 2 ** (8 - partial_octet)))
        else
            octet_value=0
        fi

        if [ -z "$mask" ]; then
            mask=$octet_value
        else
            mask="${mask}.${octet_value}"
        fi
    done

    printf "%s\n" "$mask"
}

prompt_with_default() {
    local prompt=$1
    local default=$2
    local value

    read -r -p "$prompt [$default]: " value
    if [ -z "$value" ]; then
        value=$default
    fi
    printf "%s\n" "$value"
}

prompt_required() {
    local prompt=$1
    local value

    while true; do
        read -r -p "$prompt: " value
        if [ -n "$value" ]; then
            printf "%s\n" "$value"
            return
        fi
        echo "Please enter a value."
    done
}

prompt_yes_no() {
    local prompt=$1
    local default=$2
    local value

    while true; do
        read -r -p "$prompt [$default]: " value
        value=${value:-$default}
        case "${value,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

prompt_interface() {
    local prompt=$1
    local default=$2
    local allow_blank=${3:-0}
    local value

    while true; do
        if [ "$allow_blank" -eq 1 ]; then
            read -r -p "$prompt [$default, leave blank to skip]: " value
            if [ -z "$value" ]; then
                printf "\n"
                return
            fi
        else
            read -r -p "$prompt [$default]: " value
            value=${value:-$default}
        fi

        if is_valid_interface "$value"; then
            printf "%s\n" "$value"
            return
        fi

        echo "Interface '$value' was not found. Available interfaces: $(list_candidate_interfaces | tr '\n' ' ')"
    done
}

prompt_ip() {
    local prompt=$1
    local default=$2
    local value

    while true; do
        value=$(prompt_with_default "$prompt" "$default")
        if validate_ip "$value"; then
            printf "%s\n" "$value"
            return
        fi
        echo "Please enter a valid IPv4 address."
    done
}

prompt_cidr() {
    local prompt=$1
    local default=$2
    local value

    while true; do
        value=$(prompt_with_default "$prompt" "$default")
        if validate_cidr "$value"; then
            printf "%s\n" "$value"
            return
        fi
        echo "Please enter a CIDR prefix between 1 and 32."
    done
}

prompt_target_mode() {
    local value

    while true; do
        read -r -p "How will the target device connect to this router? [wifi/ethernet] [${TARGET_LINK_MODE}]: " value
        value=${value:-$TARGET_LINK_MODE}
        case "${value,,}" in
            wifi|w)
                TARGET_LINK_MODE="wifi"
                return
                ;;
            ethernet|eth|e)
                TARGET_LINK_MODE="ethernet"
                return
                ;;
            *)
                echo "Enter 'wifi' or 'ethernet'."
                ;;
        esac
    done
}

load_session_config() {
    if [ ! -f "$SESSION_CONFIG_FILE" ]; then
        return
    fi

    while IFS='=' read -r name value; do
        case "$name" in
            BR_IFACE|WAN_IFACE|LAN_IFACE|WIFI_IFACE|TARGET_LINK_MODE|WIFI_SSID|WIFI_PASSWORD|WIFI_COUNTRY_CODE|WIFI_CHANNEL|LAN_IP|LAN_SUBNET|LAN_CIDR|LAN_DHCP_START|LAN_DHCP_END|LAN_DNS_SERVER|LAN_DHCP_LEASE)
                printf -v "$name" '%s' "$value"
                ;;
        esac
    done < "$SESSION_CONFIG_FILE"
}

save_session_config() {
    cat <<EOF > "$SESSION_CONFIG_FILE"
BR_IFACE=$BR_IFACE
WAN_IFACE=$WAN_IFACE
LAN_IFACE=$LAN_IFACE
WIFI_IFACE=$WIFI_IFACE
TARGET_LINK_MODE=$TARGET_LINK_MODE
WIFI_SSID=$WIFI_SSID
WIFI_PASSWORD=$WIFI_PASSWORD
WIFI_COUNTRY_CODE=$WIFI_COUNTRY_CODE
WIFI_CHANNEL=$WIFI_CHANNEL
LAN_IP=$LAN_IP
LAN_SUBNET=$LAN_SUBNET
LAN_CIDR=$LAN_CIDR
LAN_DHCP_START=$LAN_DHCP_START
LAN_DHCP_END=$LAN_DHCP_END
LAN_DNS_SERVER=$LAN_DNS_SERVER
LAN_DHCP_LEASE=$LAN_DHCP_LEASE
EOF
}

check_dependencies() {
    local missing=()
    local required_bins=(dnsmasq brctl ifconfig iptables ip sudo)

    if [ "$TARGET_LINK_MODE" = "wifi" ]; then
        required_bins+=(hostapd)
    fi

    for bin in "${required_bins[@]}"; do
        if ! command_exists "$bin"; then
            missing+=("$bin")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        printf "Missing dependencies: %s\n" "${missing[*]}"
        exit 1
    fi
}

service_action() {
    local action=$1
    local svc=$2

    if [ -n "$SYSTEMCTL" ]; then
        sudo "$SYSTEMCTL" "$action" "$svc" >/dev/null 2>&1 || true
    elif [ -n "$SERVICE_CMD" ]; then
        sudo "$SERVICE_CMD" "$svc" "$action" >/dev/null 2>&1 || true
    fi
}

capture_service_state() {
    if [ -n "$SYSTEMCTL" ]; then
        local nm_state="inactive"
        local wpa_state="inactive"
        if sudo "$SYSTEMCTL" is-active --quiet NetworkManager; then
            nm_state="active"
        fi
        if sudo "$SYSTEMCTL" is-active --quiet wpa_supplicant; then
            wpa_state="active"
        fi
        cat <<EOF > "$SERVICE_STATE_FILE"
NetworkManager=$nm_state
wpa_supplicant=$wpa_state
EOF
    else
        rm -f "$SERVICE_STATE_FILE"
    fi
}

capture_router_state() {
    local ip_forward

    ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    cat <<EOF > "$ROUTER_STATE_FILE"
IP_FORWARD=$ip_forward
EOF
}

restore_service_state() {
    if [ -z "$SYSTEMCTL" ] || [ ! -f "$SERVICE_STATE_FILE" ]; then
        return
    fi

    while IFS='=' read -r name state; do
        if [ "$state" = "active" ]; then
            service_action start "$name"
        fi
    done < "$SERVICE_STATE_FILE"

    rm -f "$SERVICE_STATE_FILE"
}

restore_router_state() {
    if [ ! -f "$ROUTER_STATE_FILE" ]; then
        return
    fi

    while IFS='=' read -r name value; do
        case "$name" in
            IP_FORWARD)
                sudo sysctl -w net.ipv4.ip_forward="$value" >/dev/null 2>&1 || true
                ;;
        esac
    done < "$ROUTER_STATE_FILE"

    rm -f "$ROUTER_STATE_FILE"
}

stop_daemons() {
    local services=(wpa_supplicant hostapd dnsmasq)
    local svc

    for svc in "${services[@]}"; do
        sudo killall "$svc" >/dev/null 2>&1 || true
    done
}

set_nm_managed() {
    local value=$1

    if [ -n "$NMCLI" ] && [ -n "$WIFI_IFACE" ] && is_valid_interface "$WIFI_IFACE"; then
        sudo "$NMCLI" device set "$WIFI_IFACE" managed "$value" >/dev/null 2>&1 || true
    fi
}

reset_interfaces() {
    local iface

    print_header "Resetting interfaces"
    for iface in "$LAN_IFACE" "$BR_IFACE" "$WIFI_IFACE"; do
        if [ -n "$iface" ] && ip link show "$iface" >/dev/null 2>&1; then
            sudo ifconfig "$iface" 0.0.0.0 >/dev/null 2>&1 || true
            sudo ifconfig "$iface" down >/dev/null 2>&1 || true
        fi
    done
    sudo brctl delbr "$BR_IFACE" >/dev/null 2>&1 || true
}

cleanup_router() {
    load_session_config

    if [ "$ROUTER_ACTIVE" -eq 0 ]; then
        restore_service_state
        restore_router_state
        return
    fi

    print_header "Cleaning up router state"
    stop_daemons
    reset_interfaces
    set_nm_managed yes
    restore_service_state
    restore_router_state
    rm -f "$SESSION_CONFIG_FILE"
    ROUTER_ACTIVE=0
}

write_dnsmasq_config() {
    cat <<EOF > "$DNSMASQ_CONF"
interface=${BR_IFACE}
bind-interfaces
dhcp-authoritative
dhcp-range=${LAN_DHCP_START},${LAN_DHCP_END},${LAN_SUBNET},${LAN_DHCP_LEASE}
dhcp-option=3,${LAN_IP}
dhcp-option=6,${LAN_DNS_SERVER}
EOF
}

write_hostapd_config() {
    cat <<EOF > "$HOSTAPD_CONF"
interface=${WIFI_IFACE}
bridge=${BR_IFACE}
ssid=${WIFI_SSID}
country_code=${WIFI_COUNTRY_CODE}
hw_mode=g
channel=${WIFI_CHANNEL}
wpa=2
wpa_passphrase=${WIFI_PASSWORD}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
ieee80211n=1
EOF
}

print_configuration_summary() {
    print_header "Configuration summary"
    echo "WAN uplink interface : $WAN_IFACE"
    echo "Target link mode     : $TARGET_LINK_MODE"
    echo "Target network iface : $LAN_IFACE"
    echo "Bridge interface     : $BR_IFACE"
    echo "Bridge IP            : $LAN_IP/$LAN_CIDR"
    echo "DHCP range           : $LAN_DHCP_START - $LAN_DHCP_END"
    echo "DNS server           : $LAN_DNS_SERVER"
    if [ "$TARGET_LINK_MODE" = "wifi" ]; then
        echo "Wi-Fi AP interface   : $WIFI_IFACE"
        echo "Wi-Fi SSID           : $WIFI_SSID"
        echo "Wi-Fi password       : $WIFI_PASSWORD"
        echo "Wi-Fi country/channel: $WIFI_COUNTRY_CODE / $WIFI_CHANNEL"
    fi
}

interactive_setup() {
    show_interface_overview

    print_header "MITM router setup"
    echo "This wizard will configure the Linux box as an analysis router."
    echo "You will choose the uplink interface, the target-facing interface, and whether the target joins over Wi-Fi or Ethernet."

    WAN_IFACE=$(prompt_interface "Internet uplink interface (the side with Internet access)" "$WAN_IFACE")
    LAN_IFACE=$(prompt_interface "Target-facing Ethernet interface" "$LAN_IFACE")
    BR_IFACE=$(prompt_with_default "Bridge interface name to create" "$BR_IFACE")

    prompt_target_mode

    if [ "$TARGET_LINK_MODE" = "wifi" ]; then
        WIFI_IFACE=$(prompt_interface "Wi-Fi interface to use for the target access point" "$WIFI_IFACE")
        WIFI_SSID=$(prompt_with_default "Wi-Fi SSID for the target device" "$WIFI_SSID")
        WIFI_PASSWORD=$(prompt_with_default "Wi-Fi password for the target device" "$WIFI_PASSWORD")
        WIFI_COUNTRY_CODE=$(prompt_with_default "Wi-Fi country code" "$WIFI_COUNTRY_CODE")
        WIFI_CHANNEL=$(prompt_with_default "Wi-Fi channel" "$WIFI_CHANNEL")
    else
        WIFI_IFACE=""
    fi

    LAN_IP=$(prompt_ip "Bridge IPv4 address" "$LAN_IP")
    LAN_CIDR=$(prompt_cidr "Bridge CIDR prefix length" "$LAN_CIDR")
    LAN_SUBNET=$(cidr_to_netmask "$LAN_CIDR")
    LAN_DHCP_START=$(prompt_ip "DHCP start address" "$LAN_DHCP_START")
    LAN_DHCP_END=$(prompt_ip "DHCP end address" "$LAN_DHCP_END")
    LAN_DNS_SERVER=$(prompt_ip "DNS server to hand to the target device" "$LAN_DNS_SERVER")
    LAN_DHCP_LEASE=$(prompt_with_default "DHCP lease time" "$LAN_DHCP_LEASE")

    print_configuration_summary
    echo
    if [ "$TARGET_LINK_MODE" = "wifi" ]; then
        echo "Target instructions: connect the IoT device to Wi-Fi SSID '$WIFI_SSID'."
    else
        echo "Target instructions: plug the IoT device into Ethernet interface '$LAN_IFACE'."
    fi

    if ! prompt_yes_no "Proceed with this setup?" "yes"; then
        exit 0
    fi
}

start_router() {
    check_dependencies
    capture_service_state
    capture_router_state
    save_session_config
    trap cleanup_router EXIT INT TERM

    print_header "Stopping conflicting services"
    service_action stop NetworkManager
    service_action stop wpa_supplicant
    stop_daemons

    if [ "$TARGET_LINK_MODE" = "wifi" ]; then
        set_nm_managed no
    fi

    reset_interfaces
    ROUTER_ACTIVE=1

    print_header "Writing dnsmasq config"
    write_dnsmasq_config

    if [ "$TARGET_LINK_MODE" = "wifi" ]; then
        print_header "Writing hostapd config"
        write_hostapd_config
    fi

    print_header "Bringing up interfaces and bridge"
    sudo ifconfig "$WAN_IFACE" up
    sudo ifconfig "$LAN_IFACE" up
    if [ "$TARGET_LINK_MODE" = "wifi" ] && [ -n "$WIFI_IFACE" ]; then
        sudo ifconfig "$WIFI_IFACE" up
    fi

    sudo brctl addbr "$BR_IFACE"
    sudo brctl addif "$BR_IFACE" "$LAN_IFACE"
    sudo ifconfig "$BR_IFACE" up

    print_header "Configuring IP forwarding and NAT"
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sudo iptables --flush
    sudo iptables -t nat --flush
    sudo iptables -t nat -A POSTROUTING -o "$WAN_IFACE" -j MASQUERADE
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A FORWARD -i "$BR_IFACE" -o "$WAN_IFACE" -j ACCEPT
    # Optional MITM rule example:
    # sudo iptables -t nat -A PREROUTING -i "$BR_IFACE" -p tcp -d 1.2.3.4 --dport 443 -j REDIRECT --to-ports 8081

    print_header "Assigning bridge IP"
    sudo ifconfig "$BR_IFACE" inet "$LAN_IP" netmask "$LAN_SUBNET"

    print_header "Starting dnsmasq"
    sudo dnsmasq -C "$DNSMASQ_CONF"

    if [ "$TARGET_LINK_MODE" = "wifi" ]; then
        print_header "Starting hostapd"
        echo "Press Ctrl+C when you want to stop the router and restore the system state."
        sudo hostapd "$HOSTAPD_CONF"
    else
        print_header "Router is ready"
        echo "The target should now be connected to '$LAN_IFACE'."
        echo "Press Ctrl+C when you want to stop the router and restore the system state."
        while true; do
            sleep 3600
        done
    fi
}

stop_router() {
    load_session_config
    print_header "Stopping router services"
    stop_daemons
    reset_interfaces
    set_nm_managed yes
    restore_service_state
    restore_router_state
    rm -f "$SESSION_CONFIG_FILE"
}

if [ $# -ne 1 ]; then
    usage
    exit 1
fi

case "$1" in
    up|down)
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac

SCRIPT_RELATIVE_DIR=$(dirname "${BASH_SOURCE[0]}")
cd "$SCRIPT_RELATIVE_DIR"

if [ "$1" = "up" ]; then
    interactive_setup
    start_router
else
    stop_router
fi
