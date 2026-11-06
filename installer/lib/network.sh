#!/usr/bin/env bash
# Jupiter installer - networking.
#
# NetworkManager is used for the live session as well as the installed
# system, so the installer can rely on nmcli for everything.

net_ethernet_device() {
    nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null |
        awk -F: '$2 == "ethernet" && $3 == "connected" { print $1; exit }'
}

# Online means "the package mirrors are reachable", not "ICMP works":
# public networks routinely drop ping while HTTP is fine, and refusing to
# install because of that would be wrong. ICMP is the fast path; DNS plus a
# TCP handshake on 443 is the reliable one.
net_online() {
    ping -c1 -W2 -q 1.1.1.1 >/dev/null 2>&1 && return 0
    getent ahostsv4 archlinux.org >/dev/null 2>&1 || return 1
    timeout 4 bash -c 'exec 3<>/dev/tcp/archlinux.org/443' 2>/dev/null
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

# net_copy_profiles TARGET - carry the live session's saved connections
# into the installed system. Without this, the Wi-Fi network configured
# during installation is forgotten and the new system boots offline.
net_copy_profiles() {
    local target=$1
    local source="${JUPITER_NM_PROFILES:-/etc/NetworkManager/system-connections}"
    local -a profiles=()

    [[ -d ${source} ]] || return 0
    mapfile -t profiles < <(find "${source}" -maxdepth 1 -type f -name '*.nmconnection' 2>/dev/null)
    (( ${#profiles[@]} > 0 )) || return 0

    install -d -m 700 "${target}/etc/NetworkManager/system-connections"
    # Profiles hold the PSK in clear text; NetworkManager refuses them unless
    # they are root-owned and not readable by anyone else.
    install -m 600 "${profiles[@]}" "${target}/etc/NetworkManager/system-connections/"
    printf 'Copied %s NetworkManager profile(s)\n' "${#profiles[@]}"
}

# net_connect_wifi SSID [PASSWORD] [HIDDEN]
net_connect_wifi() {
    local ssid=$1 password=${2:-} hidden=${3:-no}
    local -a args=(device wifi connect "${ssid}")

    [[ -n ${password} ]] && args+=(password "${password}")
    [[ ${hidden} == "yes" ]] && args+=(hidden yes)

    nmcli --wait 60 "${args[@]}"
}
