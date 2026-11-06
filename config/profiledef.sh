#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# Jupiter's archiso profile. Exercises only UEFI, because the installer
# uses systemd-boot and refuses to run on legacy BIOS.

iso_name="jupiter"
iso_label="JUPITER_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Jupiter Linux <https://jupiter.example>"
iso_application="Jupiter Linux Live Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="jupiter"
buildmodes=('iso')
bootmodes=('uefi.systemd-boot')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')
file_permissions=(
    ["/root"]="0:0:750"
    ["/root/.bash_profile"]="0:0:644"
    ["/usr/local/bin/jupiter-install"]="0:0:755"
    ["/usr/share/jupiter/installer/install.sh"]="0:0:755"
)
