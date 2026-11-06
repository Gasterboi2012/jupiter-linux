#!/usr/bin/env bash
# Build Jupiter's live ISO.
#
#   1. build the local packages (branding, and the AUR packages Jupiter ships)
#   2. collect them into a local pacman repository that travels inside the ISO
#   3. assemble an archiso profile and hand it to mkarchiso
#
# Run as your normal user: makepkg refuses root, and the final mkarchiso
# step is invoked through sudo.

set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR="${PROJECT_DIR}/build"
REPO_DIR="${BUILD_DIR}/repo"
AUR_DIR="${BUILD_DIR}/aur"
SOURCE_DIR="${BUILD_DIR}/sources"
PROFILE_DIR="${BUILD_DIR}/profile"
WORK_DIR="${BUILD_DIR}/work"
OUT_DIR="${PROJECT_DIR}/out"

LOCAL_PACKAGES=(jupiter-branding)
AUR_PACKAGES=(paru-bin vesktop-bin zen-browser-bin)

# Packages the build host has to provide for mkarchiso and for packaging.
# pacman-contrib supplies updpkgsums, which keeps the local package
# checksums in step with the artwork.
BUILD_PACKAGES=(archiso dosfstools mtools squashfs-tools libisoburn pacman-contrib)

log() {
    printf '\033[1;33m==>\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

check_environment() {
    [[ ${EUID} -ne 0 ]] || die "Run build.sh as a normal user (it calls sudo for mkarchiso)."

    command -v pacman >/dev/null 2>&1 || die "This is not an Arch system."
    command -v makepkg >/dev/null 2>&1 || die "makepkg is missing; install base-devel."
    command -v repo-add >/dev/null 2>&1 || die "repo-add is missing; it ships with pacman."
    command -v updpkgsums >/dev/null 2>&1 || die "updpkgsums is missing; install pacman-contrib."
    command -v git >/dev/null 2>&1 || die "git is missing."
    command -v sudo >/dev/null 2>&1 || die "sudo is missing."

    local missing=()
    local package
    for package in "${BUILD_PACKAGES[@]}"; do
        pacman -Q "${package}" >/dev/null 2>&1 || missing+=("${package}")
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing build packages: ${missing[*]}. Install them with: sudo pacman -S ${missing[*]}"
    fi
}

prepare_directories() {
    install -d "${BUILD_DIR}" "${AUR_DIR}" "${OUT_DIR}"
    rm -rf "${REPO_DIR}" "${SOURCE_DIR}"
    install -d "${REPO_DIR}" "${SOURCE_DIR}"
}

build_local_packages() {
    local package directory staged
    for package in "${LOCAL_PACKAGES[@]}"; do
        directory="${PROJECT_DIR}/packages/${package}"
        [[ -f ${directory}/PKGBUILD ]] || die "No PKGBUILD in ${directory}"

        # Build from a copy under build/: updpkgsums rewrites the PKGBUILD,
        # and a build must never leave the git checkout dirty or pick up a
        # stale src/ tree from an earlier run.
        staged="${SOURCE_DIR}/${package}"
        cp -a "${directory}" "${staged}"
        rm -rf "${staged}/src" "${staged}/pkg"
        rm -f "${staged}"/*.pkg.tar.*

        log "Updating checksums for ${package}"
        ( cd "${staged}" && updpkgsums >/dev/null )

        log "Building ${package}"
        ( cd "${staged}" && makepkg -sCf --noconfirm )
        cp "${staged}"/*.pkg.tar.zst "${REPO_DIR}/"
    done
}

build_aur_packages() {
    local package directory
    for package in "${AUR_PACKAGES[@]}"; do
        directory="${AUR_DIR}/${package}"

        if [[ -d ${directory}/.git ]]; then
            log "Updating AUR package ${package}"
            git -C "${directory}" pull --ff-only --quiet
        else
            log "Fetching AUR package ${package}"
            git clone --depth 1 --quiet "https://aur.archlinux.org/${package}.git" "${directory}"
        fi

        log "Building ${package}"
        ( cd "${directory}" && makepkg -sCf --noconfirm )
        cp "${directory}"/*.pkg.tar.zst "${REPO_DIR}/"
    done
}

make_repository() {
    local packages=("${REPO_DIR}"/*.pkg.tar.zst)
    (( ${#packages[@]} > 0 )) || die "No packages were built."

    log "Creating local repository"
    repo-add --new --remove "${REPO_DIR}/jupiter.db.tar.gz" "${packages[@]}" >/dev/null
}

# Git keeps symlinks; a source tarball may not. Recreate anything the live
# session relies on so the build works either way.
ensure_symlink() {
    local path=$1 target=$2
    install -d "$(dirname -- "${path}")"
    if [[ -L ${path} && $(readlink -- "${path}") == "${target}" ]]; then
        return
    fi
    rm -rf "${path}"
    ln -s "${target}" "${path}"
}

assemble_profile() {
    log "Assembling the archiso profile"

    rm -rf "${PROFILE_DIR}"
    cp -a "${PROJECT_DIR}/config" "${PROFILE_DIR}"

    # Pacman configuration used to build the live system and to install the
    # target system (multilib is enabled for Steam).
    install -m644 "${PROJECT_DIR}/installer/assets/pacman.conf" "${PROFILE_DIR}/pacman.conf"

    # Installer and branding artwork.
    install -d "${PROFILE_DIR}/airootfs/usr/share/jupiter"
    cp -a "${PROJECT_DIR}/installer" "${PROFILE_DIR}/airootfs/usr/share/jupiter/installer"
    install -m644 "${PROJECT_DIR}/packages/jupiter-branding/logo.txt" \
        "${PROFILE_DIR}/airootfs/usr/share/jupiter/installer/logo.txt"
    chmod 755 "${PROFILE_DIR}/airootfs/usr/share/jupiter/installer/install.sh"

    # The package repository the installer pulls Jupiter's own packages from.
    install -d "${PROFILE_DIR}/airootfs/srv/jupiter/repo"
    cp -a "${REPO_DIR}/." "${PROFILE_DIR}/airootfs/srv/jupiter/repo/"

    ensure_symlink \
        "${PROFILE_DIR}/airootfs/etc/systemd/system/multi-user.target.wants/NetworkManager.service" \
        /usr/lib/systemd/system/NetworkManager.service
}

build_iso() {
    log "Building the ISO (sudo required)"
    sudo mkarchiso -v -w "${WORK_DIR}" -o "${OUT_DIR}" "${PROFILE_DIR}"
}

main() {
    check_environment
    prepare_directories
    build_local_packages
    build_aur_packages
    make_repository
    assemble_profile
    build_iso

    log "Done."
    find "${OUT_DIR}" -maxdepth 1 -name '*.iso' -printf '  %p\n'
}

main "$@"
