#!/usr/bin/env bash
# Jupiter installer - building the target system.
#
# Package selection is deliberately short: a working KDE Plasma desktop,
# the applications Jupiter ships, and nothing else.

INSTALLER_ASSETS="${SCRIPT_DIR}/assets"

# The live medium carries its package repository here. Overridable so the
# installer can be exercised by tests without touching system paths.
JUPITER_REPO_SOURCE="${JUPITER_REPO_SOURCE:-/srv/jupiter/repo}"
JUPITER_RUN_DIR="${JUPITER_RUN_DIR:-/run/jupiter}"
JUPITER_REPO_MOUNT="${JUPITER_REPO_MOUNT:-${JUPITER_RUN_DIR}/repo}"

PACKAGES_BASE=(
    base
    linux
    linux-firmware
    sudo
    networkmanager
    wpa_supplicant
)

PACKAGES_DESKTOP=(
    plasma-desktop
    plasma-login-manager
    plasma-nm
    plasma-pa
    plasma-workspace-wallpapers
    kscreen
    konsole
    dolphin
    kinfocenter
    breeze
    breeze-icons
    noto-fonts
    pipewire
    pipewire-pulse
    pipewire-alsa
    wireplumber
    xdg-desktop-portal-kde
    kwallet
)

PACKAGES_APPS=(
    gnome-disk-utility
    steam
    fastfetch
    base-devel
    git
    efibootmgr
)

# Built into the ISO's local [jupiter] repository.
PACKAGES_JUPITER=(
    jupiter-branding
    paru-bin
    zen-browser-bin
    vesktop-bin
)

# progress PERCENT [MESSAGE]
# The percentage feeds the installer gauge (fd 3); the message goes to the
# install log.
progress() {
    local percent=$1 message=${2:-}
    if { true >&3; } 2>/dev/null; then
        printf '%s\n' "${percent}" >&3
    fi
    printf '  [%3s%%] %s\n' "${percent}" "${message}"
}

# Graphics stack for the selected driver. Steam needs both a 64-bit and a
# 32-bit Vulkan driver, so the Mesa path names the vendor driver explicitly.
driver_packages() {
    if [[ ${DRIVER} == "nvidia-open" ]]; then
        printf 'nvidia-open\nlib32-nvidia-utils\n'
    else
        printf 'mesa\nlib32-mesa\n'
        vulkan_driver_packages
    fi
}

target_packages() {
    local -a packages=(
        "${PACKAGES_BASE[@]}"
        "${PACKAGES_DESKTOP[@]}"
        "${PACKAGES_APPS[@]}"
        "${PACKAGES_JUPITER[@]}"
    )
    local -a graphics=()

    mapfile -t graphics < <(driver_packages)
    packages+=("${graphics[@]}")

    if [[ -n ${UCODE} ]]; then
        packages+=("${UCODE}")
    fi

    printf '%s\n' "${packages[@]}"
}

# Expose the ISO's package repository to both the live environment
# (pacstrap runs here) and the chroot, under the same path.
prepare_local_repo() {
    if [[ ! -d ${JUPITER_REPO_SOURCE} ]]; then
        printf 'Local package repository is missing: %s\n' "${JUPITER_REPO_SOURCE}" >&2
        return 1
    fi

    install -d -m 755 "${JUPITER_REPO_MOUNT}" "${JUPITER_RUN_DIR}"
    if ! mountpoint -q "${JUPITER_REPO_MOUNT}"; then
        mount --bind "${JUPITER_REPO_SOURCE}" "${JUPITER_REPO_MOUNT}"
    fi

    install -m 644 "${INSTALLER_ASSETS}/pacman.conf" "${JUPITER_RUN_DIR}/pacman.conf"
    cat >> "${JUPITER_RUN_DIR}/pacman.conf" <<'EOF'

[jupiter]
SigLevel = Optional TrustAll
Server = file:///run/jupiter/repo
EOF
}

release_local_repo() {
    if mountpoint -q "${JUPITER_REPO_MOUNT}" 2>/dev/null; then
        umount "${JUPITER_REPO_MOUNT}" 2>/dev/null || true
    fi
}

install_packages() {
    local -a packages=()
    mapfile -t packages < <(target_packages)

    progress 20 "Installing ${#packages[@]} packages"
    pacstrap -K -C "${JUPITER_RUN_DIR}/pacman.conf" "${MNT}" "${packages[@]}" || return $?

    # The installed system keeps the plain configuration: the live
    # repository disappears with the installer medium.
    install -m 644 "${INSTALLER_ASSETS}/pacman.conf" "${MNT}/etc/pacman.conf" || return $?
}

write_fstab() {
    progress 55 "Writing /etc/fstab"
    : >"${MNT}/etc/fstab"
    genfstab -U "${MNT}" >>"${MNT}/etc/fstab" || return $?
}

# Write the configuration script that runs inside the new system. Values
# are quoted with %q so nothing in a username or password is re-evaluated.
write_post_script() {
    local post="${MNT}/root/.jupiter-post.sh"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -Eeuo pipefail\n'
        printf 'umask 022\n'
        printf "trap 'rm -f /root/.jupiter-post.sh' EXIT\n"
        printf 'TIMEZONE=%q\n' "${TIMEZONE}"
        printf 'LOCALE=%q\n' "${LOCALE}"
        printf 'HOSTNAME=%q\n' "${HOSTNAME}"
        printf 'USERNAME=%q\n' "${USERNAME}"
        printf 'USER_FULLNAME=%q\n' "${USER_FULLNAME}"
        printf 'USER_PASSWORD=%q\n' "${USER_PASSWORD}"
        printf 'ROOT_PASSWORD=%q\n' "${ROOT_PASSWORD}"
        printf 'DRIVER=%q\n' "${DRIVER}"
        printf 'UCODE=%q\n' "${UCODE}"
        printf 'DISK=%q\n' "${TARGET_DISK}"
        printf 'ROOT_UUID=%q\n' "${ROOT_UUID}"
        cat "${INSTALLER_ASSETS}/post-install.sh"
    } >"${post}"

    chmod 700 "${post}"
}

run_post_script() {
    progress 68 "Configuring the installed system"
    arch-chroot "${MNT}" /root/.jupiter-post.sh
    rm -f "${MNT}/root/.jupiter-post.sh"
}

finish_install() {
    progress 95 "Saving the installer log"
    install -d -m 755 "${MNT}/var/log"
    install -m 644 "${LOG}" "${MNT}/var/log/jupiter-install.log"

    sync
    release_local_repo
    disk_unmount_target
    progress 100 "Installation complete"
}

install_system() {
    progress 2 "Preparing ${TARGET_DISK}"

    # Fail before touching the disk if the package repository is missing.
    prepare_local_repo || return $?

    disk_partition "${TARGET_DISK}" || return $?

    ROOT_UUID=$(blkid -s UUID -o value "${DISK_ROOT}") || return $?
    if [[ -z ${ROOT_UUID} ]]; then
        printf 'Could not read the root filesystem UUID from %s\n' "${DISK_ROOT}" >&2
        return 1
    fi

    install_packages || return $?
    write_fstab || return $?
    write_post_script || return $?
    run_post_script || return $?
    finish_install || return $?
}
