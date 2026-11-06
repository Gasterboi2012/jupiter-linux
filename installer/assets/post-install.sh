# shellcheck shell=bash
# Jupiter post-install configuration.
#
# This file is appended to a generated script that defines these variables:
#   TIMEZONE LOCALE HOSTNAME USERNAME USER_FULLNAME USER_PASSWORD
#   ROOT_PASSWORD DRIVER UCODE DISK ROOT_UUID
# It runs inside the newly installed system via arch-chroot.

# --- clock, locale, console ------------------------------------------------
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

printf 'LANG=%s\n' "${LOCALE}" >/etc/locale.conf
printf 'KEYMAP=us\n' >/etc/vconsole.conf

locale_pattern=${LOCALE//./\\.}
if ! grep -qxF "${LOCALE} UTF-8" /etc/locale.gen; then
    sed -i "s/^#[[:space:]]*${locale_pattern}[[:space:]]\+UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
    if ! grep -qxF "${LOCALE} UTF-8" /etc/locale.gen; then
        printf '%s UTF-8\n' "${LOCALE}" >>/etc/locale.gen
    fi
fi
locale-gen

# --- identity -------------------------------------------------------------
printf '%s\n' "${HOSTNAME}" >/etc/hostname
{
    printf '127.0.0.1\tlocalhost\n'
    printf '::1\t\tlocalhost\n'
    printf '127.0.1.1\t%s.localdomain\t%s\n' "${HOSTNAME}" "${HOSTNAME}"
} >/etc/hosts

systemd-machine-id-setup >/dev/null 2>&1 || true

# --- user account ---------------------------------------------------------
if [[ -n ${USER_FULLNAME} ]]; then
    useradd -m -c "${USER_FULLNAME}" -G wheel,video,audio,storage -s /bin/bash "${USERNAME}"
else
    useradd -m -G wheel,video,audio,storage -s /bin/bash "${USERNAME}"
fi
printf '%s:%s\n' "${USERNAME}" "${USER_PASSWORD}" | chpasswd

if [[ -n ${ROOT_PASSWORD} ]]; then
    printf 'root:%s\n' "${ROOT_PASSWORD}" | chpasswd
else
    # No root password: administration goes through sudo.
    passwd -l root >/dev/null
fi

install -d -m 750 /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel >/dev/null

# --- graphics -------------------------------------------------------------
if [[ ${DRIVER} == "nvidia-open" ]]; then
    printf 'options nvidia_drm modeset=1 fbdev=1\n' >/etc/modprobe.d/jupiter-nvidia.conf
    install -d -m 755 /etc/mkinitcpio.conf.d
    printf 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' \
        >/etc/mkinitcpio.conf.d/jupiter-nvidia.conf
fi

# --- services -------------------------------------------------------------
systemctl enable NetworkManager.service >/dev/null
systemctl enable systemd-timesyncd.service >/dev/null
systemctl enable fstrim.timer >/dev/null 2>&1 || true
systemctl set-default graphical.target >/dev/null

if ! systemctl enable plasmalogin.service >/dev/null 2>&1; then
    ln -sf /usr/lib/systemd/system/plasmalogin.service \
        /etc/systemd/system/display-manager.service
fi

# --- initramfs ------------------------------------------------------------
mkinitcpio -P

# --- boot loader ----------------------------------------------------------
# --no-variables keeps bootctl from writing NVRAM from inside the chroot;
# efibootmgr adds the entry instead.
bootctl --esp-path=/boot --no-variables install >/dev/null
if command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr --create --disk "${DISK}" --part 1 --label "Jupiter" \
        --loader '\EFI\systemd\systemd-bootx64.efi' >/dev/null 2>&1 || true
fi

cat >/boot/loader/loader.conf <<'LOADER'
default  jupiter.conf
timeout  2
console-mode max
editor   no
LOADER

{
    printf 'title   Jupiter Linux\n'
    printf 'linux   /vmlinuz-linux\n'
    if [[ -n ${UCODE} ]]; then
        printf 'initrd  /%s.img\n' "${UCODE}"
    fi
    printf 'initrd  /initramfs-linux.img\n'
    printf 'options root=UUID=%s rw quiet loglevel=3\n' "${ROOT_UUID}"
} >/boot/loader/entries/jupiter.conf

{
    printf 'title   Jupiter Linux (fallback initramfs)\n'
    printf 'linux   /vmlinuz-linux\n'
    if [[ -n ${UCODE} ]]; then
        printf 'initrd  /%s.img\n' "${UCODE}"
    fi
    printf 'initrd  /initramfs-linux-fallback.img\n'
    printf 'options root=UUID=%s rw quiet loglevel=3\n' "${ROOT_UUID}"
} >/boot/loader/entries/jupiter-fallback.conf

sync
