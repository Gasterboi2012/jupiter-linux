#!/usr/bin/env bash
# Jupiter installer - networking.
#
# NetworkManager is used for the live session as well as the installed
# system, so the installer can rely on nmcli for everything.

net_ethernet_device() {
    nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null |
        awk -F: '$2 == "ethernet" && $3 == "connected" { print $1; exit }'
}

net_online() {
    ping -c1 -W2 -q 1.1.1.1 >/dev/null 2>&1 || return 1
    getent ahostsv4 archlinux.org >/dev/null 2>&1
}

# net_wait_online SECONDS
net_wait_online() {
    local timeout=${1:-30} waited=0
    while (( waited < timeout )); do
        net_online && return 0
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

net_wifi_devices() {
    nmcli -t -f DEVICE,TYPE device status 2>/dev/null |
        awk -F: '$2 == "wifi" { print $1 }'
}

# net_wifi_scan - print "ssid|signal|security", strongest first.
net_wifi_scan() {
    local line ssid signal security
    local -a rows=()
    local -A seen=()

    while IFS= read -r line; do
        # SSIDs are escaped by nmcli (-t), so split on the last two fields.
        [[ ${line} =~ ^(.*):([0-9]+):(.*)$ ]] || continue
        ssid=${BASH_REMATCH[1]}
        signal=${BASH_REMATCH[2]}
        security=${BASH_REMATCH[3]}

        ssid=${ssid//\\:/:}
        ssid=${ssid//\\\\/\\}

        [[ -z ${ssid} ]] && continue
        [[ -n ${seen[${ssid}]+x} ]] && continue
        seen[${ssid}]=1

        rows+=("${ssid}|${signal}|${security:---}")
    done < <(nmcli -t -f SSID,SIGNAL,SECURITY device wifi list --rescan yes 2>/dev/null)

    (( ${#rows[@]} == 0 )) && return 0
    printf '%s\n' "${rows[@]}" | sort -t'|' -k2,2nr
}

# net_connect_wifi SSID [PASSWORD] [HIDDEN]
net_connect_wifi() {
    local ssid=$1 password=${2:-} hidden=${3:-no}
    local -a args=(device wifi connect "${ssid}")

    [[ -n ${password} ]] && args+=(password "${password}")
    [[ ${hidden} == "yes" ]] && args+=(hidden yes)

    nmcli --wait 60 "${args[@]}"
}
