#!/bin/sh

set -eu

IFACE="wlan0"
STATE_DIR="/tmp/gemini_wifi"
STATUS_FILE="$STATE_DIR/status"
SSID_FILE="$STATE_DIR/ssid"
PASS_FILE="$STATE_DIR/pass"
FLAGS_FILE="$STATE_DIR/flags"
ERROR_FILE="$STATE_DIR/error"
FALLBACK_CONF="$STATE_DIR/wpa_supplicant.conf"
CTRL_DIR="/var/run/wpa_supplicant"
NWC="/usr/local/bin/nw_control"
WPA_CLI="/usr/local/bin/wpa_cli"
WPA_SUPPLICANT="/usr/local/bin/wpa_supplicant"
UDHCPC_SCRIPT="/usr/local/etc/wifimanager/default.script"

mkdir -p "$STATE_DIR"

log_error() {
    printf '%s\n' "$1" >"$ERROR_FILE"
}

clear_error() {
    rm -f "$ERROR_FILE"
}

last_error() {
    if [ -f "$ERROR_FILE" ]; then
        cat "$ERROR_FILE"
    fi
}

run_wpa() {
    "$WPA_CLI" -p "$CTRL_DIR" -i "$IFACE" "$@" 2>/dev/null
}

run_wpa_ok() {
    output="$(run_wpa "$@" || true)"
    [ "$output" = "OK" ]
}

set_network_value() {
    netid="$1"
    field="$2"
    value="$3"

    if ! run_wpa_ok set_network "$netid" "$field" "$value"; then
        log_error "Failed to configure $field for $ssid."
        return 1
    fi
    return 0
}

require_secure_password() {
    case "$flags" in
        *WEP*)
            [ -n "$pass" ]
            ;;
        *)
            [ "${#pass}" -ge 8 ]
            ;;
    esac
}

wait_for_wpa() {
    i=0
    while [ "$i" -lt 15 ]; do
        if run_wpa ping | grep -q "PONG"; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

get_status_value() {
    key="$1"
    run_wpa status | awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }'
}

get_ip_addr() {
    ip="$(get_status_value ip_address || true)"
    if [ -n "$ip" ]; then
        printf '%s\n' "$ip"
        return 0
    fi
    ifconfig "$IFACE" 2>/dev/null | awk '/inet addr:/ { sub(/^.*inet addr:/, "", $2); print $2; exit } /^ *inet / { print $2; exit }'
}

take_over_wifi() {
    clear_error

    "$NWC" --startup >/dev/null 2>&1 || true
    "$NWC" --ebdev wifi >/dev/null 2>&1 || true
    "$NWC" --dbap "$IFACE" >/dev/null 2>&1 || true
    "$NWC" --dbsta "$IFACE" >/dev/null 2>&1 || true

    killall hostapd >/dev/null 2>&1 || true
    killall udhcpd >/dev/null 2>&1 || true
    killall udhcpc >/dev/null 2>&1 || true

    ifconfig "$IFACE" down >/dev/null 2>&1 || true
    ifconfig "$IFACE" 0.0.0.0 >/dev/null 2>&1 || true
    ifconfig "$IFACE" up >/dev/null 2>&1 || true

    "$NWC" --ebsta "$IFACE" >/dev/null 2>&1 || true

    if ! wait_for_wpa; then
        cat >"$FALLBACK_CONF" <<EOF
ctrl_interface=$CTRL_DIR
update_config=0
ap_scan=1
EOF
        killall wpa_supplicant >/dev/null 2>&1 || true
        "$WPA_SUPPLICANT" -B -i "$IFACE" -c "$FALLBACK_CONF" >/dev/null 2>&1 || true
    fi

    if ! wait_for_wpa; then
        log_error "Unable to start station-mode supplicant."
        return 1
    fi

    run_wpa disconnect >/dev/null 2>&1 || true
    run_wpa remove_network all >/dev/null 2>&1 || true
    printf '1\n' >"$STATUS_FILE"
    return 0
}

scan_networks() {
    clear_error

    if [ ! -f "$STATUS_FILE" ]; then
        log_error "Wi-Fi is still in stock AP mode. Reconfigure first."
        return 1
    fi

    if ! wait_for_wpa; then
        log_error "wpa_supplicant control socket is unavailable."
        return 1
    fi

    run_wpa scan >/dev/null 2>&1 || {
        log_error "Scan request failed."
        return 1
    }

    sleep 3

    run_wpa scan_results | \
        awk 'BEGIN { FS="\t" } NR > 1 && NF >= 5 && $5 != "" {
            secure = ($4 ~ /(WPA|WEP|SAE)/) ? 1 : 0;
            print $3 "\t" secure "\t" $4 "\t" $5;
        }'
}

connect_network() {
    clear_error

    if [ ! -f "$STATUS_FILE" ]; then
        log_error "Wi-Fi is still in stock AP mode. Reconfigure first."
        return 1
    fi

    if ! wait_for_wpa; then
        log_error "wpa_supplicant control socket is unavailable."
        return 1
    fi

    if [ ! -f "$SSID_FILE" ]; then
        log_error "Missing SSID request."
        return 1
    fi

    ssid="$(cat "$SSID_FILE")"
    pass=""
    flags=""
    if [ -f "$PASS_FILE" ]; then
        pass="$(cat "$PASS_FILE")"
    fi
    if [ -f "$FLAGS_FILE" ]; then
        flags="$(cat "$FLAGS_FILE")"
    fi

    if [ -n "$flags" ] && ! require_secure_password; then
        case "$flags" in
            *WEP*)
                log_error "This WEP network needs a password."
                ;;
            *)
                log_error "Wi-Fi passwords must be at least 8 characters."
                ;;
        esac
        return 1
    fi

    esc_ssid="$(printf '%s' "$ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    esc_pass="$(printf '%s' "$pass" | sed 's/\\/\\\\/g; s/"/\\"/g')"

    run_wpa disconnect >/dev/null 2>&1 || true
    run_wpa remove_network all >/dev/null 2>&1 || true
    netid="$(run_wpa add_network | tail -n 1 | tr -d '\r')"
    case "$netid" in
        ''|*[!0-9]*)
            log_error "Failed to allocate a Wi-Fi network slot."
            return 1
            ;;
    esac

    if ! set_network_value "$netid" ssid "\"$esc_ssid\""; then
        return 1
    fi

    if [ -n "$pass" ]; then
        case "$flags" in
            *WEP*)
                if ! set_network_value "$netid" key_mgmt NONE ||
                   ! set_network_value "$netid" auth_alg OPEN ||
                   ! set_network_value "$netid" wep_key0 "\"$esc_pass\""; then
                    return 1
                fi
                ;;
            *)
                if ! set_network_value "$netid" psk "\"$esc_pass\""; then
                    return 1
                fi
                ;;
        esac
    else
        if ! set_network_value "$netid" key_mgmt NONE; then
            return 1
        fi
    fi

    if ! run_wpa_ok enable_network "$netid"; then
        log_error "Failed to enable Wi-Fi network $ssid."
        return 1
    fi
    if ! run_wpa_ok select_network "$netid"; then
        log_error "Failed to select Wi-Fi network $ssid."
        return 1
    fi
    run_wpa reassociate >/dev/null 2>&1 || true

    i=0
    while [ "$i" -lt 20 ]; do
        state="$(get_status_value wpa_state || true)"
        if [ "$state" = "COMPLETED" ]; then
            break
        fi
        i=$((i + 1))
        sleep 1
    done

    state="$(get_status_value wpa_state || true)"
    if [ "$state" != "COMPLETED" ]; then
        log_error "Authentication failed or timed out (state: ${state:-unknown})."
        run_wpa disconnect >/dev/null 2>&1 || true
        return 1
    fi

    killall udhcpc >/dev/null 2>&1 || true
    if ! udhcpc -q -n -t 5 -T 3 -i "$IFACE" -s "$UDHCPC_SCRIPT" >/dev/null 2>&1; then
        log_error "Connected to $ssid, but DHCP did not return an IP address."
        return 1
    fi
    if [ -z "$(get_ip_addr || true)" ]; then
        log_error "Connected to $ssid, but no IP address is present yet."
        return 1
    fi
    return 0
}

disconnect_network() {
    clear_error
    run_wpa disconnect >/dev/null 2>&1 || true
    run_wpa remove_network all >/dev/null 2>&1 || true
    killall udhcpc >/dev/null 2>&1 || true
    ifconfig "$IFACE" 0.0.0.0 >/dev/null 2>&1 || true
}

print_status() {
    reconfigured="0"
    if [ -f "$STATUS_FILE" ]; then
        reconfigured="1"
    fi

    ssid="$(get_status_value ssid || true)"
    wpa_state="$(get_status_value wpa_state || true)"
    ip="$(get_ip_addr || true)"
    internet="0"
    message=""

    if [ -n "$ip" ]; then
        if ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 || ping -c 1 1.1.1.1 >/dev/null 2>&1; then
            internet="1"
        fi
    fi

    if [ "$reconfigured" = "0" ]; then
        message="Stock AP mode is still active."
    elif [ "$wpa_state" = "COMPLETED" ] && [ -n "$ip" ] && [ "$internet" = "1" ]; then
        message="Connected with internet access."
    elif [ "$wpa_state" = "COMPLETED" ] && [ -n "$ip" ]; then
        message="Connected, but internet check failed."
    elif [ -n "$ssid" ]; then
        message="Connecting to $ssid..."
    else
        message="Station mode is ready for scanning."
    fi

    err="$(last_error || true)"
    if [ -n "$err" ]; then
        message="$err"
    fi

    printf 'reconfigured=%s\n' "$reconfigured"
    printf 'wpa_state=%s\n' "$wpa_state"
    printf 'ssid=%s\n' "$ssid"
    printf 'ip=%s\n' "$ip"
    printf 'internet=%s\n' "$internet"
    printf 'message=%s\n' "$message"
}

case "${1:-status}" in
    reconfigure)
        take_over_wifi
        print_status
        ;;
    scan)
        scan_networks
        ;;
    connect)
        connect_network
        print_status
        ;;
    disconnect)
        disconnect_network
        print_status
        ;;
    status)
        print_status
        ;;
    *)
        echo "Usage: gemini_wifi.sh {status|reconfigure|scan|connect|disconnect}" >&2
        exit 1
        ;;
esac
