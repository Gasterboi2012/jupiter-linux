#!/usr/bin/env bash
# Jupiter installer - disk discovery, partitioning and mounting.
#
# This is the only file that destroys data. It always works on a single,
# explicitly selected whole disk: one EFI system partition and one ext4 root.

TARGET_DISK=""
DISK_ESP=""
DISK_ROOT=""

# The disk the live medium boots from, so it can never be offered as a target.
_live_disk() {
    if [[ -n ${JUPITER_TEST_LIVE_DISK:-} ]]; then
        printf '%s\n' "${JUPITER_TEST_LIVE_DISK}"
        return 0
    fi

    local source parent
    source=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
    [[ -n ${source} ]] || return 0

    parent=$(lsblk -no PKNAME -- "${source}" 2>/dev/null | head -n1)
    [[ -n ${parent} ]] && printf '/dev/%s\n' "${parent}"
}

# A disk with mounted partitions is in use; never offer it.
_disk_in_use() {
    local disk=$1
    [[ -n $(lsblk -nlo MOUNTPOINT -- "${disk}" 2>/dev/null | tr -d '[:space:]') ]]
}

# disks_list - print "device|size|model" for every candidate disk.
disks_list() {
    local live name size type model
    live=$(_live_disk)

    while read -r name size type || [[ -n ${name:-} ]]; do
        [[ ${type} == "disk" ]] || continue
        [[ -n ${live} && ${name} == "${live}" ]] && continue
        _disk_in_use "${name}" && continue

        model=$(lsblk -dno MODEL -- "${name}" 2>/dev/null |
            tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
        printf '%s|%s|%s\n' "${name}" "${size}" "${model:-Unknown model}"
    done < <(lsblk -dpno NAME,SIZE,TYPE 2>/dev/null)
}

# Partition device names follow the kernel's numbering scheme (nvme0n1p1
# versus sda1).
_set_partition_names() {
    local disk=$1 suffix=""
    [[ ${disk} =~ [0-9]$ ]] && suffix="p"
    DISK_ESP="${disk}${suffix}1"
    DISK_ROOT="${disk}${suffix}2"
}

# disk_partition DISK - GPT layout, format, mount at $MNT.
disk_partition() {
    local disk=$1
    _set_partition_names "${disk}"

    progress 6 "Wiping ${disk}"
    umount -R "${MNT}" 2>/dev/null || true
    sgdisk --zap-all "${disk}"
    sgdisk --new=1:0:+1024M --typecode=1:ef00 --change-name=1:JUPITER_ESP "${disk}"
    sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:JUPITER_ROOT "${disk}"
    partprobe "${disk}" 2>/dev/null || true
    udevadm settle --timeout=15 2>/dev/null || sleep 2

    progress 10 "Formatting ${DISK_ESP} (EFI system partition)"
    wipefs -a "${DISK_ESP}" >/dev/null 2>&1 || true
    mkfs.fat -F 32 -n JUPITER_ESP "${DISK_ESP}" >/dev/null

    progress 14 "Formatting ${DISK_ROOT} (ext4)"
    wipefs -a "${DISK_ROOT}" >/dev/null 2>&1 || true
    mkfs.ext4 -F -L JUPITER_ROOT "${DISK_ROOT}" >/dev/null

    mount "${DISK_ROOT}" "${MNT}"
    install -d -m 755 "${MNT}/boot"
    mount "${DISK_ESP}" "${MNT}/boot"

    # Used by lib/system.sh when the install starts.
    # shellcheck disable=SC2034
    TARGET_DISK="${disk}"
}

disk_unmount_target() {
    if mountpoint -q "${MNT}/boot" 2>/dev/null; then
        umount "${MNT}/boot" 2>/dev/null || true
    fi
    if mountpoint -q "${MNT}" 2>/dev/null; then
        umount -R "${MNT}" 2>/dev/null || true
    fi
}
