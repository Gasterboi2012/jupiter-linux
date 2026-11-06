#!/usr/bin/env bash
# Jupiter Linux installer.
#
# A deliberately small, linear TUI installer: network, disk, timezone,
# account, hostname, graphics, summary. Everything else is decided for the
# user so an install is a handful of keystrokes.

set -Eeuo pipefail

# shellcheck source-path=SCRIPTDIR
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Used by the sourced lib/ modules.
# shellcheck disable=SC2034
MNT=${JUPITER_MNT:-/mnt}
LOG=${JUPITER_LOG:-/tmp/jupiter-install.log}
JUPITER_VERSION=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || printf 'rolling')

# shellcheck source=lib/ui.sh
source "${SCRIPT_DIR}/lib/ui.sh"
# shellcheck source=lib/detect.sh
source "${SCRIPT_DIR}/lib/detect.sh"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/lib/validate.sh"
# shellcheck source=lib/timezone.sh
source "${SCRIPT_DIR}/lib/timezone.sh"
# shellcheck source=lib/disk.sh
source "${SCRIPT_DIR}/lib/disk.sh"
# shellcheck source=lib/network.sh
source "${SCRIPT_DIR}/lib/network.sh"
# shellcheck source=lib/system.sh
source "${SCRIPT_DIR}/lib/system.sh"

TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
HOSTNAME="jupiter"
USERNAME=""
USER_FULLNAME=""
USER_PASSWORD=""
ROOT_PASSWORD=""
DRIVER="mesa"
UCODE=""
# Filled in during the install and used by the sourced lib/ modules.
# shellcheck disable=SC2034
ROOT_UUID=""

# --- preflight -------------------------------------------------------------

require_root() {
    if [[ ${EUID} -eq 0 || ${JUPITER_TEST_NONROOT:-0} == 1 ]]; then
        return 0
    fi
    printf 'The Jupiter installer must run as root.\n' >&2
    exit 1
}

require_uefi() {
    is_uefi && return 0
    ui_msgbox "UEFI required" "Jupiter boots with systemd-boot and installs on UEFI systems only.\n\nThis machine booted in legacy BIOS mode.\nEnable UEFI in the firmware settings and start the\ninstaller again from the USB medium."
    return 1
}

screen_splash() {
    local logo="J U P I T E R"
    if [[ -f ${SCRIPT_DIR}/logo.txt ]]; then
        logo=$(cat "${SCRIPT_DIR}/logo.txt")
    fi

    ui_msgbox "Welcome" "${logo}\n\n\Z3Jupiter ${JUPITER_VERSION}\Z0  -  a minimal Arch-based desktop.\n\nThis installer sets up KDE Plasma, Plasma Login Manager\nand the applications Jupiter ships, with as few packages\nas possible.\n\n\Z1Nothing is written to disk until you confirm the summary.\Z0\n\n\Z3Already on ethernet? Network setup is skipped automatically.\Z0"
}

# --- steps -----------------------------------------------------------------

step_network() {
    local ethernet choice

    ethernet=$(net_ethernet_device)

    if [[ -n ${ethernet} ]] && net_online; then
        ui_msgbox "Network" "\Z3${ethernet}\Z0 is connected and online.\n\nNetwork setup is not needed, so Jupiter skips it."
        return 0
    fi

    if [[ -n ${ethernet} ]]; then
        ui_msgbox "Network" "Ethernet (${ethernet}) is connected, but there is no\ninternet access yet.\n\nDHCP may still be negotiating: retry in a moment, or\nset up Wi-Fi instead."
    fi

    while :; do
        if ! choice=$(ui_menu "Network" "Jupiter downloads packages during installation, so an\ninternet connection is required.\n\nHow do you want to connect?" \
            "wifi" "Connect to a Wi-Fi network" \
            "retry" "Retry ethernet / check the connection"); then
            return 1
        fi

        case ${choice} in
            wifi)
                if wifi_flow && net_online; then
                    ui_msgbox "Network" "Connected. Installation can continue."
                    return 0
                fi
                ;;
            retry)
                if net_online; then
                    ui_msgbox "Network" "Connected. Installation can continue."
                    return 0
                fi
                ui_msgbox "Network" "Still offline.\n\nCheck the cable, or choose Wi-Fi."
                ;;
        esac
    done
}

wifi_flow() {
    local -a devices=() menu=() networks=()
    local device choice ssid signal security password="" hidden="no" row

    mapfile -t devices < <(net_wifi_devices)
    if (( ${#devices[@]} == 0 )); then
        ui_msgbox "Wi-Fi" "No wireless interface was found on this machine."
        return 1
    fi

    if (( ${#devices[@]} == 1 )); then
        device=${devices[0]}
    else
        for device in "${devices[@]}"; do
            menu+=("${device}" "Wireless interface")
        done
        if ! device=$(ui_menu "Wi-Fi" "Select a wireless interface." "${menu[@]}"); then
            return 1
        fi
    fi

    ui_infobox "Wi-Fi" "Scanning for networks on ${device}..."
    nmcli device wifi rescan ifname "${device}" >/dev/null 2>&1 || true
    sleep 3

    mapfile -t networks < <(net_wifi_scan)
    if (( ${#networks[@]} == 0 )); then
        ui_msgbox "Wi-Fi" "No networks were found.\n\nMove closer to the access point and try again."
        return 1
    fi

    menu=()
    for row in "${networks[@]}"; do
        IFS='|' read -r ssid signal security <<<"${row}"
        menu+=("${ssid}" "${signal}%   ${security}")
    done
    menu+=("__hidden__" "Join a hidden network")

    if ! choice=$(ui_menu "Wi-Fi" "Select a network." "${menu[@]}"); then
        return 1
    fi

    if [[ ${choice} == "__hidden__" ]]; then
        if ! choice=$(ui_input "Wi-Fi" "Enter the network name (SSID):" ""); then
            return 1
        fi
        if [[ -z ${choice} ]]; then
            return 1
        fi
        hidden="yes"
        if ! password=$(ui_password "Wi-Fi" "Password for ${choice} (leave empty if the network is open):"); then
            return 1
        fi
    else
        security=""
        for row in "${networks[@]}"; do
            IFS='|' read -r ssid signal security <<<"${row}"
            if [[ ${ssid} == "${choice}" ]]; then
                break
            fi
        done
        if [[ -n ${security} && ${security} != "--" ]]; then
            if ! password=$(ui_password "Wi-Fi" "Password for ${choice}:"); then
                return 1
            fi
        fi
    fi

    ui_infobox "Wi-Fi" "Connecting to ${choice}..."
    if ! net_connect_wifi "${choice}" "${password}" "${hidden}" >>"${LOG}" 2>&1; then
        ui_msgbox "Wi-Fi" "Could not connect to ${choice}.\n\nCheck the password and try again."
        return 1
    fi

    if net_wait_online 25; then
        return 0
    fi

    ui_msgbox "Wi-Fi" "Connected to ${choice}, but the internet is still\nunreachable.\n\nCaptive portals are not supported by the installer."
    return 1
}

step_disk() {
    local -a menu=() disks=()
    local row device size model choice confirmation bytes

    mapfile -t disks < <(disks_list)
    if (( ${#disks[@]} == 0 )); then
        ui_msgbox "No disks" "No usable disk was found.\n\nDisks with mounted filesystems, and the medium the\ninstaller booted from, are never offered."
        return 1
    fi

    for row in "${disks[@]}"; do
        IFS='|' read -r device size model <<<"${row}"
        menu+=("${device}" "${size}  ${model}")
    done

    if ! choice=$(ui_menu "Disk" "\Z1Choose the disk Jupiter will be installed on.\nEvery partition and every file on it will be erased.\Z0\n\nLayout: 1 GiB EFI system partition + ext4 root." "${menu[@]}"); then
        return 1
    fi

    bytes=$(lsblk -bno SIZE -- "${choice}" 2>/dev/null | head -n1)
    if [[ -n ${bytes} ]] && (( bytes < 20 * 1024 * 1024 * 1024 )); then
        if ! ui_yesno "Small disk" "${choice} is smaller than 20 GiB.\n\nAfter the system, Steam and the bundled browsers\nthere will be very little room left.\n\nContinue anyway?" "Continue" "Back"; then
            return 1
        fi
    fi

    if ! confirmation=$(ui_input "Erase ${choice}" "\Z1This cannot be undone.\Z0\n\nType \Z3ERASE\Z0 to confirm that ${choice} may be wiped:" ""); then
        return 1
    fi

    if [[ ${confirmation} != "ERASE" ]]; then
        ui_msgbox "Cancelled" "${choice} was left untouched."
        return 1
    fi

    TARGET_DISK=${choice}
}

step_timezone() {
    local -a regions=() menu=() cities=() city_menu=()
    local region row zone description choice

    mapfile -t regions < <(tz_regions)
    for region in "${regions[@]}"; do
        if [[ ${region} == "UTC" ]]; then
            menu+=("${region}" "Coordinated Universal Time")
        else
            menu+=("${region}" "Cities in ${region}")
        fi
    done

    if ! region=$(ui_menu "Timezone" "Select a region." "${menu[@]}"); then
        return 1
    fi

    if [[ ${region} == "UTC" ]]; then
        TIMEZONE="UTC"
        return 0
    fi

    mapfile -t cities < <(tz_cities "${region}")
    if (( ${#cities[@]} == 0 )); then
        ui_msgbox "Timezone" "No timezone found for ${region}."
        return 1
    fi

    for row in "${cities[@]}"; do
        IFS='|' read -r zone description <<<"${row}"
        city_menu+=("${zone}" "${description}")
    done

    if ! choice=$(ui_menu "Timezone" "Select a city in ${region}." "${city_menu[@]}"); then
        return 1
    fi

    TIMEZONE=${choice}
}

step_account() {
    local username full_name password confirm root_choice root_pw root_confirm

    while :; do
        if ! username=$(ui_input "Account" "Choose a username.\n\nLowercase letters, digits, '-' and '_'.\nIt must start with a letter or '_'." ""); then
            return 1
        fi
        if valid_username "${username}"; then
            break
        fi
        ui_msgbox "Invalid username" "\"${username}\" cannot be used.\n\nUse lowercase letters, digits, '-' or '_',\nstart with a letter, and pick a name that is\nnot a system account."
    done

    if ! full_name=$(ui_input "Account" "Full name for ${username} (optional).\nIt is shown on the login screen." ""); then
        return 1
    fi

    while :; do
        if ! password=$(ui_password "Password" "Set a password for ${username}:"); then
            return 1
        fi
        if [[ -z ${password} ]]; then
            ui_msgbox "Password" "The password cannot be empty."
            continue
        fi
        if [[ ${password} == *:* ]]; then
            ui_msgbox "Password" "The password cannot contain ':'."
            continue
        fi
        if ! confirm=$(ui_password "Password" "Repeat the password:"); then
            return 1
        fi
        if [[ ${password} != "${confirm}" ]]; then
            ui_msgbox "Password" "The passwords do not match."
            continue
        fi
        break
    done

    # Consumed by write_post_script in lib/system.sh.
    # shellcheck disable=SC2034
    USERNAME=${username}
    # shellcheck disable=SC2034
    USER_FULLNAME=${full_name}
    # shellcheck disable=SC2034
    USER_PASSWORD=${password}

    if ! root_choice=$(ui_menu "Root account" "How should the root account be handled?" \
        "locked" "Lock root and use sudo (recommended)" \
        "password" "Set a separate root password"); then
        return 1
    fi

    ROOT_PASSWORD=""
    if [[ ${root_choice} == "password" ]]; then
        while :; do
            if ! root_pw=$(ui_password "Root password" "Set the root password:"); then
                return 1
            fi
            if [[ -z ${root_pw} ]]; then
                ui_msgbox "Root password" "The password cannot be empty."
                continue
            fi
            if [[ ${root_pw} == *:* ]]; then
                ui_msgbox "Root password" "The password cannot contain ':'."
                continue
            fi
            if ! root_confirm=$(ui_password "Root password" "Repeat the root password:"); then
                return 1
            fi
            if [[ ${root_pw} != "${root_confirm}" ]]; then
                ui_msgbox "Root password" "The passwords do not match."
                continue
            fi
            break
        done
        ROOT_PASSWORD=${root_pw}
    fi
}

step_hostname() {
    local name
    while :; do
        if ! name=$(ui_input "Hostname" "Choose a name for this machine.\nIt is used on the network and in the terminal prompt." "jupiter"); then
            return 1
        fi
        if valid_hostname "${name}"; then
            HOSTNAME=${name}
            return 0
        fi
        ui_msgbox "Invalid hostname" "\"${name}\" is not a valid hostname.\n\nUse letters, digits and '-', start and end with\na letter or digit, and keep it under 64 characters."
    done
}

step_driver() {
    local gpus detected choice
    gpus=$(gpu_description)
    detected="No graphics information could be read."
    if [[ -n ${gpus} ]]; then
        detected="Detected: ${gpus}"
    fi

    # Read by ui_menu in lib/ui.sh.
    # shellcheck disable=SC2034
    UI_DEFAULT_ITEM="mesa"
    if has_nvidia_gpu; then
        # shellcheck disable=SC2034
        UI_DEFAULT_ITEM="nvidia-open"
    fi

    if ! choice=$(ui_menu "Graphics" "${detected}\n\nChoose the graphics driver stack." \
        "mesa" "Intel, AMD or software rendering (most systems)" \
        "nvidia-open" "NVIDIA open kernel modules (Turing / RTX and newer)"); then
        return 1
    fi

    if [[ ${choice} == "nvidia-open" ]] && ! has_nvidia_gpu; then
        if ! ui_yesno "NVIDIA drivers" "No NVIDIA GPU was detected on this machine.\n\nThe NVIDIA modules may not load on a different GPU.\n\nInstall them anyway?" "Install" "Back"; then
            return 1
        fi
    fi

    DRIVER=${choice}
    UCODE=$(cpu_ucode_package)
}

step_summary() {
    local root_account="locked (sudo)" driver_label="Mesa (Intel/AMD/software)"
    local text

    if [[ -n ${ROOT_PASSWORD} ]]; then
        root_account="password set"
    fi
    if [[ ${DRIVER} == "nvidia-open" ]]; then
        driver_label="NVIDIA open kernel modules"
    fi

    text="
  \Z3Disk\Z0          ${TARGET_DISK}
  \Z3Layout\Z0        1 GiB EFI system partition + ext4 root
  \Z3Hostname\Z0      ${HOSTNAME}
  \Z3Timezone\Z0      ${TIMEZONE}
  \Z3Locale\Z0        ${LOCALE}
  \Z3User\Z0          ${USERNAME} (wheel, sudo)
  \Z3Root\Z0          ${root_account}
  \Z3Graphics\Z0      ${driver_label}
  \Z3Microcode\Z0     ${UCODE:-none needed}
  \Z3Desktop\Z0       KDE Plasma + Plasma Login Manager
  \Z3Apps\Z0          Zen Browser, Vesktop, Steam, GNOME Disks, Paru

  \Z1${TARGET_DISK} will be erased when you continue.\Z0
"

    ui_yesno "Ready to install" "${text}\nBegin the installation?" "Install" "Back"
}

# --- install ---------------------------------------------------------------

run_installation() {
    local fifo pid rc=0 tail_output

    fifo=$(mktemp -u /tmp/jupiter-fifo.XXXXXX)
    mkfifo -m 600 "${fifo}"
    : >"${LOG}"

    (
        exec 3>"${fifo}"
        install_system
    ) >>"${LOG}" 2>&1 &
    pid=$!

    # Read by ui_gauge in lib/ui.sh.
    # shellcheck disable=SC2034
    UI_BACKTITLE=" Jupiter  ·  Installing"
    ui_gauge "Installing Jupiter" "Installing Jupiter Linux.\n\nPartitioning, downloading packages and configuring\nthe system. This usually takes a few minutes." <"${fifo}"

    wait "${pid}" || rc=$?
    rm -f "${fifo}"

    if (( rc != 0 )); then
        tail_output=$(tail -n 20 "${LOG}" 2>/dev/null || true)
        ui_msgbox "Installation failed" "The installation stopped (exit code ${rc}).\n\n\Z1Last lines of ${LOG}:\Z0\n\n${tail_output}"
        return 1
    fi
}

screen_finish() {
    local choice
    if ! choice=$(ui_menu "Installation complete" "\Z3Jupiter is installed.\Z0\n\nRemove the installation medium, then reboot into\nyour new system.\n\nInstall log: /var/log/jupiter-install.log" \
        "reboot" "Reboot into Jupiter" \
        "poweroff" "Power off" \
        "shell" "Exit to the live shell"); then
        choice="shell"
    fi

    case ${choice} in
        reboot)
            sync
            disk_unmount_target
            reboot
            ;;
        poweroff)
            sync
            disk_unmount_target
            poweroff
            ;;
        *)
            printf '\nInstallation complete. Log: %s\n' "${LOG}"
            ;;
    esac
}

cleanup() {
    local status=$?
    trap - EXIT

    release_local_repo
    disk_unmount_target
    dialog --clear >/dev/null 2>&1 || true

    if (( status != 0 )) && [[ ${JUPITER_TEST_NONROOT:-0} != 1 ]]; then
        printf '\nJupiter installer stopped. Log: %s\n' "${LOG}" >&2
    fi
}

# --- main ------------------------------------------------------------------

main() {
    require_root
    trap 'cleanup' EXIT

    if ! require_uefi; then
        exit 1
    fi

    screen_splash

    local -a steps=(
        step_network
        step_disk
        step_timezone
        step_account
        step_hostname
        step_driver
        step_summary
    )
    local -A titles=(
        [step_network]="Network"
        [step_disk]="Disk"
        [step_timezone]="Timezone"
        [step_account]="Account"
        [step_hostname]="Hostname"
        [step_driver]="Graphics"
        [step_summary]="Summary"
    )

    local i=0 total=${#steps[@]}
    while (( i < total )); do
        ui_backtitle "$((i + 1))" "${total}" "${titles[${steps[i]}]}"
        if "${steps[i]}"; then
            i=$((i + 1))
            continue
        fi

        if (( i == 0 )); then
            if ui_yesno "Quit installer" "Exit the Jupiter installer and return to the live shell?" "Exit" "Stay"; then
                exit 0
            fi
        else
            i=$((i - 1))
        fi
    done

    if ! run_installation; then
        exit 1
    fi

    disk_unmount_target
    screen_finish
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
