#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
NAT_IF="eth0"
SWITCH_IF="eth1"
DNS_SEARCH="."
MANAGED_RESOLV_CONF="/mnt/wsl-resolv.conf"
WSL_GENERATED_RESOLV_CONF="/mnt/wsl/resolv.conf"
NAT_ACTIVE_METRIC="0"
NAT_LOW_PRIORITY_METRIC="9000"
SWITCH_GATEWAY_METRIC="0"

usage() {
    echo "Usage: $0 attachOnly|useGateway|detach|applyPortForward" >&2
    exit 2
}

if [[ "$ACTION" != "attachOnly" && "$ACTION" != "useGateway" && "$ACTION" != "detach" && "$ACTION" != "applyPortForward" ]]; then
    usage
fi

load_config() {
    local powershell_exe="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    local wslpath_bin="/usr/bin/wslpath"
    local config_path helper_path

    config_path="$("$wslpath_bin" -w "${PROJECT_DIR}/config/Config.ps1")"
    helper_path="$("$wslpath_bin" -w "${PROJECT_DIR}/windows/ExportConfigForShell.ps1")"
    "$powershell_exe" -NoProfile -ExecutionPolicy Bypass \
        -File "$helper_path" -ConfigPath "$config_path" |
        tr -d '\r'
}

eval "$(load_config)"

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E "$0" "$@"
fi

attach_switch() {
    local schtasks_exe="/mnt/c/Windows/System32/schtasks.exe"
    local task_name

    if [[ -z "$W_NetworkConfig_InternalSwitchName" ]]; then
        echo "Cannot read InternalSwitchName from ${PROJECT_DIR}/config/Config.ps1" >&2
        exit 1
    fi

    task_name="\\LoopV\\AttachWslSwitch-${W_NetworkConfig_InternalSwitchName}"
    "$schtasks_exe" /Run /TN "$task_name"
}

apply_port_forwards() {
    /mnt/c/Windows/System32/schtasks.exe \
        /Run /TN '\LoopV\ApplyWslPortForwards' >/dev/null 2>&1 || true
}

wait_for_iface() {
    local iface="$1"

    for _ in $(seq 1 30); do
        if ip link show dev "$iface" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "Timed out waiting for ${iface}." >&2
    exit 1
}

remove_default_routes() {
    local iface="$1"

    while ip -4 route show default dev "$iface" | grep -q '^default '; do
        ip route del default dev "$iface" 2>/dev/null || break
    done
}

default_route_gateway() {
    local iface="$1"

    ip -4 route show default dev "$iface" |
        awk 'NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i == "via") {
                    print $(i + 1)
                    exit
                }
            }
        }'
}

set_default_route_metric() {
    local iface="$1"
    local metric="$2"
    local gateway

    gateway="${3:-$(default_route_gateway "$iface" || true)}"
    if [[ -z "$gateway" ]]; then
        echo "Cannot read default gateway from ${iface}." >&2
        exit 1
    fi

    remove_default_routes "$iface"
    ip route add default via "$gateway" dev "$iface" proto kernel metric "$metric"
}

configured_wsl_address() {
    local config_wsl_address

    config_wsl_address="$W_NetworkConfig_WslAddress"
    if [[ -z "$config_wsl_address" ]]; then
        echo "WslAddress is empty; set NetworkConfig.WslAddress." >&2
        exit 1
    fi

    if [[ "$config_wsl_address" != */* ]]; then
        config_wsl_address="${config_wsl_address}/${W_NetworkConfig_PrefixLength}"
    fi

    echo "$config_wsl_address"
}

replace_switch_address() {
    local address="$1"

    if [[ -z "$address" ]]; then
        echo "No IPv4 address exists on ${SWITCH_IF}; set NetworkConfig.WslAddress." >&2
        exit 1
    fi

    ip -4 addr flush dev "$SWITCH_IF"
    ip addr add "$address" dev "$SWITCH_IF"
}

restore_wsl_resolver() {
    if [[ -e "$WSL_GENERATED_RESOLV_CONF" ]]; then
        ln -sfn "$WSL_GENERATED_RESOLV_CONF" "$MANAGED_RESOLV_CONF"
        rm -f /etc/resolv.conf
        ln -s "$MANAGED_RESOLV_CONF" /etc/resolv.conf
    fi
}

use_vm_resolver() {
    local gateway="$1"

    rm -f "$MANAGED_RESOLV_CONF"
    {
        echo "nameserver ${gateway}"
        echo "search ${DNS_SEARCH}"
    } >"$MANAGED_RESOLV_CONF"

    rm -f /etc/resolv.conf
    ln -s "$MANAGED_RESOLV_CONF" /etc/resolv.conf
}

add_switch_default_route() {
    local gateway="$1"

    remove_default_routes "$SWITCH_IF"
    ip route add default via "$gateway" dev "$SWITCH_IF" metric "$SWITCH_GATEWAY_METRIC"
}

attach_only() {
    ip link set "$NAT_IF" up 2>/dev/null || true
    attach_switch
    wait_for_iface "$SWITCH_IF"
    ip link set "$SWITCH_IF" up
    replace_switch_address "$(configured_wsl_address)"
    remove_default_routes "$SWITCH_IF"
    set_default_route_metric "$NAT_IF" "$NAT_ACTIVE_METRIC"
    restore_wsl_resolver

    echo "LoopV WSL attach-only applied. ${NAT_IF} is primary; ${SWITCH_IF} is attached without gateway/DNS changes."
}

use_gateway() {
    local vm_gateway wsl_address

    vm_gateway="$W_NetworkConfig_VmGateway"
    wsl_address="$(configured_wsl_address)"

    if [[ -z "$vm_gateway" ]]; then
        echo "VmGateway is empty; set NetworkConfig.VmGateway." >&2
        exit 1
    fi

    attach_switch
    wait_for_iface "$SWITCH_IF"
    ip link set "$SWITCH_IF" up
    replace_switch_address "$wsl_address"
    set_default_route_metric "$NAT_IF" "$NAT_LOW_PRIORITY_METRIC"
    add_switch_default_route "$vm_gateway"
    use_vm_resolver "$vm_gateway"

    echo "LoopV WSL gateway applied. ${NAT_IF} is deprioritized; ${SWITCH_IF} uses gateway/DNS ${vm_gateway}."
}

detach() {
    ip link set "$NAT_IF" up 2>/dev/null || true

    if ip link show dev "$SWITCH_IF" >/dev/null 2>&1; then
        remove_default_routes "$SWITCH_IF"
        ip addr flush dev "$SWITCH_IF" 2>/dev/null || true
        ip link set "$SWITCH_IF" down 2>/dev/null || true
    fi

    set_default_route_metric "$NAT_IF" "$NAT_ACTIVE_METRIC"
    restore_wsl_resolver
    echo "LoopV WSL detach applied. No switch attach was requested; ${NAT_IF} is primary."
}

case "$ACTION" in
    attachOnly)
        attach_only
        apply_port_forwards
        ;;
    useGateway)
        use_gateway
        apply_port_forwards
        ;;
    detach)
        detach
        apply_port_forwards
        ;;
    applyPortForward)
        apply_port_forwards
        ;;
esac
