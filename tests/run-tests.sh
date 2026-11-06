#!/usr/bin/env bash
# Jupiter test suite.
#
# Covers the parts that can be verified without an Arch live environment:
# shell syntax, input validation, timezone lookup, nmcli parsing, branding
# consistency, and full installer runs against stubbed system commands
# (including a stub dialog that follows a scripted answer queue).

set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
STUBS="${PROJECT_DIR}/tests/stubs"
TMP_ROOT=$(mktemp -d)
if [[ ${KEEP_TEST_TMP:-0} == 1 ]]; then
    trap 'printf "test fixtures kept at %s\\n" "${TMP_ROOT}"' EXIT
else
    trap 'rm -rf "${TMP_ROOT}"' EXIT
fi

PASS=0
FAIL=0

section() {
    printf '\n\033[1m%s\033[0m\n' "$1"
}

ok() {
    PASS=$((PASS + 1))
    printf '  \033[32mok\033[0m   %s\n' "$1"
}

bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
}

assert_eq() {
    if [[ $1 == "$2" ]]; then ok "$3"; else bad "$3 (expected '$1', got '$2')"; fi
}

# assert_contains NEEDLE HAYSTACK MESSAGE
assert_contains() {
    if [[ $2 == *"$1"* ]]; then ok "$3"; else bad "$3 (missing '$1')"; fi
}

assert_missing() {
    if [[ $2 != *"$1"* ]]; then ok "$3"; else bad "$3 (unexpected '$1')"; fi
}

assert_file() {
    if [[ -f $1 ]]; then ok "$2"; else bad "$2 ($1 is missing)"; fi
}

assert_no_file() {
    if [[ ! -e $1 ]]; then ok "$2"; else bad "$2 ($1 still exists)"; fi
}

expect_true() {
    local message=$1
    shift
    if "$@"; then ok "${message}"; else bad "${message}"; fi
}

expect_false() {
    local message=$1
    shift
    if "$@"; then bad "${message}"; else ok "${message}"; fi
}

# --- syntax ----------------------------------------------------------------

section "syntax"

while IFS= read -r -d '' file; do
    if bash -n "${file}"; then
        ok "bash -n ${file#"${PROJECT_DIR}"/}"
    else
        bad "bash -n ${file#"${PROJECT_DIR}"/}"
    fi
done < <(find "${PROJECT_DIR}" -type f \
    -not -path "${PROJECT_DIR}/build/*" -not -path "${PROJECT_DIR}/out/*" \
    \( -name '*.sh' -o -name 'PKGBUILD' -o -name '*.install' -o -name '.bash_profile' \
        -o -name 'jupiter-install' -o -name 'misc' \) -print0)

while IFS= read -r -d '' file; do
    if PYTHONPYCACHEPREFIX="${TMP_ROOT}/pycache" python3 -m py_compile "${file}" 2>/dev/null; then
        ok "python ${file#"${PROJECT_DIR}"/}"
    else
        bad "python ${file#"${PROJECT_DIR}"/}"
    fi
done < <(find "${PROJECT_DIR}" -type f -name '*.py' \
    -not -path "${PROJECT_DIR}/build/*" -not -path "${PROJECT_DIR}/out/*" -print0)

SHELLCHECK=${SHELLCHECK:-shellcheck}
if command -v "${SHELLCHECK}" >/dev/null 2>&1; then
    mapfile -t scripts < <(
        find "${PROJECT_DIR}" -type f \
            -not -path "${PROJECT_DIR}/build/*" -not -path "${PROJECT_DIR}/out/*" \
            \( -name '*.sh' -o -name '*.install' -o -name '.bash_profile' \) -print
    )
    if "${SHELLCHECK}" --source-path=SCRIPTDIR -x -P "${PROJECT_DIR}" "${scripts[@]}"; then
        ok "shellcheck"
    else
        bad "shellcheck"
    fi
else
    printf '  \033[33mskip\033[0m shellcheck is not installed\n'
fi

# --- validation ------------------------------------------------------------

section "input validation"
# shellcheck source=/dev/null
source "${PROJECT_DIR}/installer/lib/validate.sh"

expect_true "valid_username: jane" valid_username jane
expect_true "valid_username: j_doe-2" valid_username j_doe-2
expect_false "valid_username: empty" valid_username ""
expect_false "valid_username: uppercase" valid_username Jane
expect_false "valid_username: leading digit" valid_username 1jane
expect_false "valid_username: reserved root" valid_username root
expect_false "valid_username: reserved systemd-" valid_username systemd-network
expect_false "valid_username: too long" valid_username "$(printf 'a%.0s' {1..40})"

expect_true "valid_hostname: jupiter-box" valid_hostname jupiter-box
expect_true "valid_hostname: j7" valid_hostname j7
expect_false "valid_hostname: empty" valid_hostname ""
expect_false "valid_hostname: leading dash" valid_hostname -jupiter
expect_false "valid_hostname: trailing dash" valid_hostname jupiter-
expect_false "valid_hostname: dot" valid_hostname jupiter.local

expect_true "valid_password: hunter2!" valid_password 'hunter2!'
expect_true "valid_password: spaces" valid_password 'two words'
expect_false "valid_password: empty" valid_password ""
expect_false "valid_password: colon" valid_password "a:b"
expect_false "valid_password: newline" valid_password $'a\nroot:evil'
expect_false "valid_password: tab" valid_password $'a\tb'
expect_false "valid_password: too long" valid_password "$(printf 'a%.0s' {1..129})"

expect_true "valid_fullname: Jane Doe" valid_fullname "Jane Doe"
expect_true "valid_fullname: empty is allowed" valid_fullname ""
expect_false "valid_fullname: newline" valid_fullname $'Jane\nDoe'
expect_false "valid_fullname: too long" valid_fullname "$(printf 'a%.0s' {1..65})"

# --- timezones -------------------------------------------------------------

section "timezones"

cat >"${TMP_ROOT}/zone.tab" <<'FIXTURE'
# test fixture
US	+404251-0740023	America/New_York	Eastern Time
DE	+5230+01322	Europe/Berlin	most of Germany
GB	+513030-0000731	Europe/London
UTC	+0000+00000	Etc/UTC	Coordinated Universal Time
FIXTURE

ZONE_TAB="${TMP_ROOT}/zone.tab"
export ZONE_TAB
# shellcheck source=/dev/null
source "${PROJECT_DIR}/installer/lib/timezone.sh"

regions=$(tz_regions)
assert_eq "UTC" "$(printf '%s\n' "${regions}" | head -n1)" "UTC is offered first"
assert_contains "Europe" "${regions}" "Europe is listed"
assert_contains "America" "${regions}" "America is listed"

european=$(tz_cities Europe)
assert_contains "Europe/Berlin|most of Germany" "${european}" "city keeps its description"
assert_contains "Europe/London|GB" "${european}" "missing description falls back to the country code"
assert_eq "" "$(tz_cities Nowhere)" "unknown regions have no cities"
assert_eq "DE" "$(tz_country Europe/Berlin)" "a zone carries its country code"
assert_eq "" "$(tz_country America/Nowhere)" "unknown zones have no country"

# --- languages and keymaps -------------------------------------------------

section "languages and keymaps"

cat >"${TMP_ROOT}/locale.gen" <<'FIXTURE'
# test fixture
#en_US.UTF-8 UTF-8
#de_DE.UTF-8 UTF-8
#fr_FR.UTF-8 UTF-8
#C.UTF-8 UTF-8
FIXTURE

mkdir -p "${TMP_ROOT}/keymaps/i386/qwerty" "${TMP_ROOT}/keymaps/i386/qwertz" \
    "${TMP_ROOT}/keymaps/mac"
: >"${TMP_ROOT}/keymaps/i386/qwerty/us.map.gz"
: >"${TMP_ROOT}/keymaps/i386/qwertz/de-latin1-nodeadkeys.map.gz"
: >"${TMP_ROOT}/keymaps/mac/mac-us.map.gz"

JUPITER_LOCALE_GEN="${TMP_ROOT}/locale.gen"
JUPITER_KEYMAP_ROOT="${TMP_ROOT}/keymaps"
export JUPITER_LOCALE_GEN JUPITER_KEYMAP_ROOT
# shellcheck source=/dev/null
source "${PROJECT_DIR}/installer/lib/locale.sh"

locales=$(locale_list)
assert_contains "en_US.UTF-8" "${locales}" "locale.gen entries are read"
assert_contains "de_DE.UTF-8" "${locales}" "commented locales are offered too"
assert_missing "C.UTF-8" "${locales}" "locales without a territory are skipped"

keymaps=$(keymap_list)
assert_contains "de-latin1-nodeadkeys" "${keymaps}" "PC keymaps are listed"
assert_contains "us" "${keymaps}" "keymaps are listed by basename"
assert_missing "mac-us" "${keymaps}" "non-PC keymaps are not offered"

assert_eq "de_DE.UTF-8|de-latin1-nodeadkeys" "$(suggestion_for_country DE)" \
    "Germany gets German defaults"
assert_eq "en_US.UTF-8|us" "$(suggestion_for_country JP)" \
    "countries without those files fall back"
assert_eq "en_US.UTF-8|us" "$(suggestion_for_country '')" "no country falls back"

# --- wifi parsing ----------------------------------------------------------

section "wifi parsing"

WIFI_LIST='Cafe\:WiFi:72:WPA2
HomeNet:81:WPA2
HomeNet:40:WPA2
OpenNet:55:
'

scan_bin="${TMP_ROOT}/scan-bin"
mkdir -p "${scan_bin}"
ln -s "${STUBS}/nmcli" "${scan_bin}/nmcli"

scan=$(PATH="${scan_bin}:${PATH}" NM_WIFI_LIST="${WIFI_LIST}" STUB_LOG="${TMP_ROOT}/scan.log" \
    bash -c "source '${PROJECT_DIR}/installer/lib/network.sh'; net_wifi_scan")

assert_eq "HomeNet|81|WPA2" "$(printf '%s\n' "${scan}" | sed -n 1p)" "strongest network comes first"
assert_contains "Cafe:WiFi|72|WPA2" "${scan}" "escaped colons in SSIDs are decoded"
assert_eq "1" "$(printf '%s\n' "${scan}" | grep -c '^HomeNet|')" "duplicate SSIDs are collapsed"
assert_contains "OpenNet|55|--" "${scan}" "open networks show no security"

# --- disk descriptions -----------------------------------------------------

section "disk descriptions"

disk_bin="${TMP_ROOT}/disk-bin"
mkdir -p "${disk_bin}"
ln -s "${STUBS}/lsblk" "${disk_bin}/lsblk"

described=$(PATH="${disk_bin}:${PATH}" STUB_LOG="${TMP_ROOT}/disk.log" \
    LSBLK_TYPES=$'disk\npart\npart' LSBLK_FSTYPES=$'ext4\nvfat' \
    bash -c "source '${PROJECT_DIR}/installer/lib/disk.sh'; _disk_contents /dev/vda")
assert_eq "2 partition(s): ext4,vfat" "${described}" "disk contents are summarised"

blank=$(PATH="${disk_bin}:${PATH}" STUB_LOG="${TMP_ROOT}/disk.log" LSBLK_TYPES='' \
    bash -c "source '${PROJECT_DIR}/installer/lib/disk.sh'; _disk_contents /dev/vdb")
assert_eq "no partitions" "${blank}" "an empty disk is described as empty"

# --- branding --------------------------------------------------------------

section "branding"

branding="${PROJECT_DIR}/packages/jupiter-branding"
os_release=$(cat "${branding}/os-release")
pkgbuild=$(cat "${branding}/PKGBUILD")
hook=$(cat "${branding}/jupiter-branding.hook")

assert_contains "ID=jupiter" "${os_release}" "os-release identifies Jupiter"
assert_contains "ID_LIKE=arch" "${os_release}" "os-release stays Arch-compatible"
assert_contains "LOGO=jupiter-logo" "${os_release}" "os-release points at the logo"
assert_file "${branding}/logo.svg" "placeholder SVG logo exists"
assert_file "${branding}/logo-256.png" "placeholder PNG logo exists"
assert_contains "/usr/share/icons/hicolor/scalable/apps/jupiter-logo.svg" "${pkgbuild}" \
    "package installs the logo where LOGO= resolves"
assert_contains "/etc/xdg/kdeglobals" "${pkgbuild}" "desktop defaults are installed"
assert_contains "/etc/xdg/kcm-about-distrorc" "${pkgbuild}" "KInfoCenter picks up distro info"
assert_file "${branding}/kcm-about-distrorc" "KInfoCenter branding file exists"
assert_contains "Target = filesystem" "${hook}" "branding hook tracks the filesystem package"
assert_contains "jupiter-branding-apply" "$(cat "${branding}/jupiter-branding.install")" \
    "branding is applied from the package scriptlet"

if python3 - "${branding}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for name in ("fastfetch.jsonc", "wallpaper-metadata.json"):
    json.loads((root / name).read_text())
PY
then
    ok "fastfetch and wallpaper configs are valid JSON"
else
    bad "fastfetch and wallpaper configs are valid JSON"
fi

if python3 - "${branding}" <<'PY'
import hashlib
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
text = (root / "PKGBUILD").read_text()
sources = re.findall(r"'([^']+)'", re.search(r"source=\((.*?)\)", text, re.S).group(1))
sums = re.findall(r"'([^']+)'", re.search(r"sha256sums=\((.*?)\)", text, re.S).group(1))
assert len(sources) == len(sums), "source and sha256sums differ in length"
for name, expected in zip(sources, sums):
    actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
    assert actual == expected, f"checksum mismatch for {name}"
PY
then
    ok "every packaged file matches its checksum"
else
    bad "every packaged file matches its checksum"
fi

# --- archiso profile -------------------------------------------------------

section "archiso profile"

profile="${PROJECT_DIR}/config"
loader="${profile}/efiboot/loader/loader.conf"
entries=("${profile}/efiboot/loader/entries"/*.conf)

# mkarchiso refuses to build uefi.systemd-boot without these.
assert_file "${loader}" "systemd-boot loader.conf is present"
if [[ -f ${entries[0]} ]]; then
    ok "the UEFI boot menu has an entry"
else
    bad "the UEFI boot menu has an entry"
fi
entry=$(cat "${entries[0]}" 2>/dev/null)
assert_contains "/%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux" "${entry}" "the boot entry loads the live kernel"
assert_contains "archisosearchuuid=%ARCHISO_UUID%" "${entry}" "the boot entry finds the ISO by UUID"

mkinitcpio_conf=$(cat "${profile}/airootfs/etc/mkinitcpio.conf.d/archiso.conf" 2>/dev/null)
assert_contains "archiso" "${mkinitcpio_conf}" "the live initramfs carries the archiso hook"

profiledef=$(cat "${profile}/profiledef.sh")
assert_contains "bootmodes=('uefi.systemd-boot')" "${profiledef}" "the profile builds UEFI media only"
assert_contains "\"/usr/share/jupiter/installer/install.sh\"" "${profiledef}" \
    "the installer is executable on the live medium"

# --- installer flows -------------------------------------------------------

WIFI_LSPCI="01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD104 [GeForce RTX 4070] [10de:2786] (rev a1)"
AMD_LSPCI="03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 23 [1002:73ff] (rev c1)"

make_sandbox() {
    local dir=$1
    mkdir -p "${dir}/bin" "${dir}/mnt" "${dir}/repo" "${dir}/run/jupiter"
    ln -s "${STUBS}/dialog" "${dir}/bin/dialog"
    ln -s "${STUBS}/nmcli" "${dir}/bin/nmcli"
    ln -s "${STUBS}/lsblk" "${dir}/bin/lsblk"

    local command
    for command in pacstrap genfstab arch-chroot blkid mount umount mountpoint \
        sgdisk partprobe udevadm wipefs mkfs.fat mkfs.ext4 lspci ping getent \
        reboot poweroff sync findmnt; do
        ln -s "${STUBS}/misc" "${dir}/bin/${command}"
    done

    : >"${dir}/stub.log"
    : >"${dir}/dialog.log"
}

run_installer() {
    local dir=$1 wifi_mode=$2 lspci_fixture=$3
    env -i \
        PATH="${dir}/bin:/usr/bin:/bin" \
        HOME="${dir}" \
        DIALOG_SCRIPT="${dir}/responses.json" \
        DIALOG_LOG="${dir}/dialog.log" \
        NM_WIFI_MODE="${wifi_mode}" \
        NM_WIFI_LIST="${WIFI_LIST}" \
        ONLINE_FILE="${dir}/online" \
        MOUNT_MARKER="${dir}/mounted" \
        STUB_LOG="${dir}/stub.log" \
        POST_SCRIPT_COPY="${dir}/post.sh" \
        TEST_ROOT_UUID="TEST-UUID-1234" \
        LSPCI_FIXTURE="${lspci_fixture}" \
        LSBLK_DISKS=$'/dev/vda 64G disk\n/dev/sdb 8G disk' \
        LSBLK_BYTES=68719476736 \
        JUPITER_TEST_NONROOT=1 \
        JUPITER_TEST_UEFI=1 \
        JUPITER_TEST_LIVE_DISK=/dev/sdb \
        JUPITER_TEST_SKIP_DEVICES=1 \
        JUPITER_MNT="${dir}/mnt" \
        JUPITER_LOG="${dir}/install.log" \
        JUPITER_REPO_SOURCE="${dir}/repo" \
        JUPITER_RUN_DIR="${dir}/run/jupiter" \
        JUPITER_LOCALE_GEN="${TMP_ROOT}/locale.gen" \
        JUPITER_KEYMAP_ROOT="${TMP_ROOT}/keymaps" \
        JUPITER_NM_PROFILES="${dir}/nm" \
        timeout 90 bash "${PROJECT_DIR}/installer/install.sh"
}

section "installer flow: ethernet, mesa, locked root"

flow_a="${TMP_ROOT}/flow-a"
make_sandbox "${flow_a}"
: >"${flow_a}/online"
cat >"${flow_a}/responses.json" <<'JSON'
["", "", "/dev/vda", "ERASE", "Europe", "Europe/Berlin", "yes",
 "jane", "Jane Doe", "hunter2!", "hunter2!", "locked",
 "jupiter-box", "mesa", "yes", "shell"]
JSON

if run_installer "${flow_a}" 0 "${AMD_LSPCI}" >"${flow_a}/console.log" 2>&1; then
    ok "installer completes"
else
    bad "installer completes"
    sed 's/^/      /' "${flow_a}/console.log" | tail -n 25
fi

pacstrap_log=$(grep '^pacstrap' "${flow_a}/stub.log" || true)
assert_contains "pacstrap -K -C ${flow_a}/run/jupiter/pacman.conf ${flow_a}/mnt" \
    "${pacstrap_log}" "pacstrap uses the generated configuration"
assert_contains "plasma-desktop" "${pacstrap_log}" "KDE Plasma is installed"
assert_contains "plasma-login-manager" "${pacstrap_log}" "Plasma Login Manager is installed"
assert_contains "gnome-disk-utility" "${pacstrap_log}" "GNOME Disks is installed"
assert_contains "steam" "${pacstrap_log}" "Steam is installed"
assert_contains "fastfetch" "${pacstrap_log}" "fastfetch is installed"
assert_contains "jupiter-branding" "${pacstrap_log}" "branding package is installed"
assert_contains "paru-bin" "${pacstrap_log}" "Paru is installed"
assert_contains "zen-browser-bin" "${pacstrap_log}" "Zen Browser is installed"
assert_contains "vesktop-bin" "${pacstrap_log}" "Vesktop is installed"
assert_missing "nvidia-open" "${pacstrap_log}" "no NVIDIA stack on a Mesa install"

installed_conf=$(cat "${flow_a}/mnt/etc/pacman.conf")
assert_contains "[multilib]" "${installed_conf}" "installed system keeps multilib for Steam"
assert_missing "[jupiter]" "${installed_conf}" "the live-only repository is not left behind"

assert_contains "TEST-UUID-1234 / ext4" "$(cat "${flow_a}/mnt/etc/fstab")" "fstab is generated"
assert_file "${flow_a}/post.sh" "post-install script is produced"
post_a=$(cat "${flow_a}/post.sh")
assert_contains "TIMEZONE=Europe/Berlin" "${post_a}" "timezone is passed to the target"
assert_contains "USERNAME=jane" "${post_a}" "user account is passed to the target"
assert_contains 'USER_FULLNAME=Jane\ Doe' "${post_a}" "full name is passed to the target"
assert_contains "HOSTNAME=jupiter-box" "${post_a}" "hostname is passed to the target"
assert_contains "ROOT_UUID=TEST-UUID-1234" "${post_a}" "root UUID is passed to the target"
assert_contains "DRIVER=mesa" "${post_a}" "Mesa is selected on a Mesa install"
assert_contains "LOCALE=de_DE.UTF-8" "${post_a}" "the language is suggested from the timezone"
assert_contains "KEYMAP=de-latin1-nodeadkeys" "${post_a}" "the keyboard is suggested from the timezone"
assert_contains "de-latin1-nodeadkeys" "$(cat "${flow_a}/dialog.log")" \
    "the summary shows the keyboard layout"
assert_contains "kbd" "${pacstrap_log}" "kbd is installed for the console keymap"
assert_no_file "${flow_a}/mnt/root/.jupiter-post.sh" \
    "the generated script does not keep the passwords in the target"
assert_contains "mesa" "${pacstrap_log}" "Mesa is installed on a Mesa install"
assert_contains "vulkan-radeon" "${pacstrap_log}" "AMD Vulkan driver satisfies Steam on a Mesa install"
assert_contains "lib32-vulkan-radeon" "${pacstrap_log}" "32-bit Vulkan driver satisfies Steam"
assert_contains "systemctl enable plasmalogin.service" "${post_a}" "Plasma Login Manager is enabled"
assert_contains "passwd -l root" "${post_a}" "root is locked when no password is set"
assert_contains "hwclock --systohc 2>/dev/null ||" "${post_a}" \
    "a missing RTC does not abort the installation"
assert_contains "systemd-boot was not written" "${post_a}" \
    "the boot loader is verified instead of assumed"
assert_contains 'options root=UUID=%s rw quiet loglevel=3' "${post_a}" \
    "boot entry template references the root UUID"

assert_contains "[100%] Installation complete" "$(cat "${flow_a}/install.log")" "progress reaches 100%"
assert_file "${flow_a}/mnt/var/log/jupiter-install.log" "installer log is kept in the new system"
assert_contains "Network setup is not needed" "$(cat "${flow_a}/dialog.log")" \
    "ethernet users skip network setup"

section "installer flow: wifi, NVIDIA, root password, back navigation"

flow_b="${TMP_ROOT}/flow-b"
make_sandbox "${flow_b}"
mkdir -p "${flow_b}/nm"
printf '[connection]\nid=home\npsk=hunter2\n' >"${flow_b}/nm/home.nmconnection"
cat >"${flow_b}/responses.json" <<'JSON'
["", "wifi", "Cafe:WiFi", "secret", "",
 "/dev/vda", "ERASE", "America", "America/New_York",
 "no", "keymap", "de-latin1-nodeadkeys", "yes",
 {"cancel": true}, "yes",
 "Bad Name", "", "jane", "", "s3cret", "s3cret",
 "password", "rootpass", "rootpass", "jupiter-box",
 "nvidia-open", "no", "nvidia-open", "yes", "shell"]
JSON

if run_installer "${flow_b}" 1 "${WIFI_LSPCI}" >"${flow_b}/console.log" 2>&1; then
    ok "installer completes over wifi"
else
    bad "installer completes over wifi"
    sed 's/^/      /' "${flow_b}/console.log" | tail -n 25
fi

post_b=$(cat "${flow_b}/post.sh")
assert_contains "DRIVER=nvidia-open" "${post_b}" "NVIDIA driver choice reaches the target"
assert_contains "options nvidia_drm modeset=1 fbdev=1" "${post_b}" "NVIDIA modeset is configured"
assert_contains "MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)" "${post_b}" \
    "NVIDIA modules are added to the initramfs"
assert_contains "ROOT_PASSWORD=rootpass" "${post_b}" "root password is passed to the target"
assert_contains "KEYMAP=de-latin1-nodeadkeys" "${post_b}" \
    "an explicitly chosen keyboard survives going back and forth"
assert_contains "LOCALE=en_US.UTF-8" "${post_b}" "changing the keyboard leaves the language alone"
language_prompts=$(grep 'Use these settings' "${flow_b}/dialog.log")
assert_eq "3" "$(printf '%s\n' "${language_prompts}" | wc -l)" \
    "cancelling the account step returns to the language step"
assert_contains "de-latin1-nodeadkeys" "$(printf '%s\n' "${language_prompts}" | tail -n1)" \
    "re-entering the language step does not reset the layout"
assert_file "${flow_b}/mnt/etc/NetworkManager/system-connections/home.nmconnection" \
    "the Wi-Fi profile is carried into the new system"
assert_eq "600" \
    "$(stat -c '%a' "${flow_b}/mnt/etc/NetworkManager/system-connections/home.nmconnection" 2>/dev/null)" \
    "the Wi-Fi profile keeps NetworkManager's permissions"

assert_contains "wifi connect Cafe:WiFi password secret" "$(cat "${flow_b}/stub.log")" \
    "wifi credentials are handed to NetworkManager"
assert_contains "nvidia-open" "$(grep '^pacstrap' "${flow_b}/stub.log")" \
    "NVIDIA stack is installed when selected"
assert_eq "2" "$(grep -c 'Choose the graphics driver stack' "${flow_b}/dialog.log")" \
    "cancelling the summary returns to the driver step"
assert_contains "cannot be used" "$(cat "${flow_b}/dialog.log")" "invalid usernames are rejected"

section "installer flow: quitting before touching the disk"

flow_c="${TMP_ROOT}/flow-c"
make_sandbox "${flow_c}"
cat >"${flow_c}/responses.json" <<'JSON'
["", {"cancel": true}, "yes"]
JSON

if run_installer "${flow_c}" 1 "${AMD_LSPCI}" >"${flow_c}/console.log" 2>&1; then
    ok "installer can be quit cleanly"
else
    bad "installer can be quit cleanly"
fi
assert_missing "pacstrap" "$(cat "${flow_c}/stub.log")" "nothing is installed when quitting early"

section "installer flow: package installation failure"

flow_d="${TMP_ROOT}/flow-d"
make_sandbox "${flow_d}"
: >"${flow_d}/online"
cat >"${flow_d}/responses.json" <<'JSON'
["", "", "/dev/vda", "ERASE", "Europe", "Europe/Berlin", "yes",
 "jane", "Jane Doe", "hunter2!", "hunter2!", "locked",
 "jupiter-box", "mesa", "yes"]
JSON

if env -i \
    PATH="${flow_d}/bin:/usr/bin:/bin" HOME="${flow_d}" \
    DIALOG_SCRIPT="${flow_d}/responses.json" DIALOG_LOG="${flow_d}/dialog.log" \
    NM_WIFI_MODE=0 NM_WIFI_LIST="${WIFI_LIST}" ONLINE_FILE="${flow_d}/online" \
    MOUNT_MARKER="${flow_d}/mounted" STUB_LOG="${flow_d}/stub.log" \
    POST_SCRIPT_COPY="${flow_d}/post.sh" TEST_ROOT_UUID="TEST-UUID-1234" \
    LSPCI_FIXTURE="${AMD_LSPCI}" LSBLK_DISKS=$'/dev/vda 64G disk' LSBLK_BYTES=68719476736 \
    JUPITER_TEST_NONROOT=1 JUPITER_TEST_UEFI=1 JUPITER_TEST_LIVE_DISK=/dev/sdb \
    JUPITER_TEST_SKIP_DEVICES=1 \
    JUPITER_LOCALE_GEN="${TMP_ROOT}/locale.gen" JUPITER_KEYMAP_ROOT="${TMP_ROOT}/keymaps" \
    JUPITER_NM_PROFILES="${flow_d}/nm" \
    JUPITER_MNT="${flow_d}/mnt" JUPITER_LOG="${flow_d}/install.log" \
    JUPITER_REPO_SOURCE="${flow_d}/repo" JUPITER_RUN_DIR="${flow_d}/run/jupiter" \
    STUB_FAIL=pacstrap \
    timeout 90 bash "${PROJECT_DIR}/installer/install.sh" >"${flow_d}/console.log" 2>&1; then
    bad "a failed pacstrap fails the installer"
else
    ok "a failed pacstrap fails the installer"
fi
assert_contains "Installation failed" "$(cat "${flow_d}/dialog.log")" "failure is reported to the user"
assert_contains "--textbox" "$(cat "${flow_d}/dialog.log")" \
    "the failure screen is scrollable instead of truncating the log"
assert_contains "stopped while installing packages" \
    "$(cat "${flow_d}/install.failure.txt" 2>/dev/null)" \
    "the failure report names the stage that failed"
assert_file "${flow_d}/install.failure.txt" "the failure report outlives the installer"
assert_no_file "${flow_d}/mnt/root/.jupiter-post.sh" \
    "a failed install leaves no password file behind"

# --- summary ---------------------------------------------------------------

printf '\n\033[1m%d passed, %d failed\033[0m\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
