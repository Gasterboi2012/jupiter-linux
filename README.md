# Jupiter

A very small Arch Linux–based desktop distribution: KDE Plasma, Plasma Login
Manager, and the handful of applications Jupiter ships. Nothing else is
installed, nothing runs that the user did not ask for.

Jupiter is built with [archiso](https://wiki.archlinux.org/title/archiso) and
installed from a text-mode TUI installer that runs automatically from the live
medium.

## What's in it

| | |
|---|---|
| Desktop | KDE Plasma (`plasma-desktop`, Konsole, Dolphin, KScreen, KWallet, PipeWire) |
| Login manager | Plasma Login Manager (`plasmalogin.service`) |
| Applications | Zen Browser, Vesktop, Steam, GNOME Disks, Paru, fastfetch |
| Boot | systemd-boot, UEFI only |
| Branding | `os-release`, `/etc/issue`, `/etc/lsb-release`, KInfoCenter, fastfetch, wallpaper |

The installed system is plain Arch underneath (`ID_LIKE=arch`), so the Arch
repositories (including `multilib`, enabled for Steam) work as usual.

## Building the ISO

Build host requirements:

```sh
sudo pacman -S --needed archiso dosfstools mtools squashfs-tools libisoburn \
    base-devel git sudo
```

Then, as a normal user (makepkg refuses to run as root):

```sh
./build.sh
```

The script:

1. builds `packages/jupiter-branding` (the only local package),
2. clones and builds the AUR packages Jupiter ships (`paru-bin`,
   `zen-browser-bin`, `vesktop-bin`) — this needs network access,
3. collects everything into a local `[jupiter]` repository,
4. assembles the archiso profile in `build/profile` and runs `mkarchiso`
   through `sudo`.

The finished image is written to `out/jupiter-*.iso`. Write it to a USB stick
with `dd` or `cat`:

```sh
sudo dd if=out/jupiter-*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Boot the medium in UEFI mode. The live system logs in as root on tty1 and
starts the installer immediately; leaving the installer returns to a shell
where `jupiter-install` starts it again.

## The installer

Seven linear steps, with `Esc`/`Cancel` to go back one step:

1. **Network** — skipped automatically when ethernet is already connected and
   online; otherwise connect to Wi-Fi or retry ethernet.
2. **Disk** — pick the disk to erase (whole disk, confirmation required).
3. **Timezone** — region, then city.
4. **Account** — username, optional full name, password, and root handling
   (locked with `sudo`, or a separate root password).
5. **Hostname**.
6. **Graphics** — `mesa` (Intel, AMD, software) or `nvidia-open`.
7. **Summary** — shows every choice before anything is written, then installs.

The disk is repartitioned as GPT with a 1 GiB EFI system partition (FAT32) and
an ext4 root. There is no swap and no encryption. Everything on the chosen
disk is destroyed.

Logs: `/tmp/jupiter-install.log` on the live medium, copied to
`/var/log/jupiter-install.log` on the installed system.

## Placeholder artwork

The logo and wallpaper are placeholders. Replace them in
`packages/jupiter-branding/` (next to `PKGBUILD` — makepkg only finds local
sources in the package directory):

- `logo.svg`, `logo-256.png`, `logo-512.png` — the logo. `os-release` sets
  `LOGO=jupiter-logo`, which resolves through the hicolor icon theme, and
  KInfoCenter reads `/etc/xdg/kcm-about-distrorc`.
- `logo.txt` — the ASCII wordmark shown by the installer.
- `wallpaper.png` / `wallpaper-preview.png` — the Plasma wallpaper.

`generate-assets.py` regenerates the placeholders (needs Pillow):

```sh
python3 packages/jupiter-branding/generate-assets.py
```

Then update the checksums, either automatically (`pacman-contrib` provides
`updpkgsums`, which `build.sh` uses when present) or by hand:

```sh
cd packages/jupiter-branding && updpkgsums
```

`build.sh` runs `updpkgsums` for you when it is installed, so a plain
`./build.sh` after swapping artwork is usually enough.

`os-release` and `/etc/issue` belong to the Arch `filesystem` package, so
`jupiter-branding` stages them in `/usr/lib/jupiter/` and applies them from its
package scriptlet and a pacman hook when `filesystem` changes.

## Tests

```sh
./tests/run-tests.sh
```

This checks shell syntax, input validation, timezone parsing, Wi-Fi output
parsing, branding consistency, and runs the installer end to end against
stubbed system commands and a scripted `dialog`, including the failure path.
Useful knobs:

- `SHELLCHECK=/path/to/shellcheck` — lint with a specific binary
  (skipped when absent).
- `KEEP_TEST_TMP=1` — keep the sandbox directories for inspection.

## Limitations

- UEFI only; legacy BIOS boot is refused.
- One disk, whole-disk erase; no encryption, LVM, swap or dual-boot setup.
- AUR packages are built from the AUR when the ISO is built, so the ISO
  reflects the AUR state at build time.
- No Secure Boot signing.
