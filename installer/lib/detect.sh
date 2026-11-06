#!/usr/bin/env bash
# Jupiter installer - hardware and platform probes.

is_uefi() {
    [[ -d /sys/firmware/efi || ${JUPITER_TEST_UEFI:-0} == 1 ]]
}

# Print the microcode package matching this CPU, if one applies.
cpu_ucode_package() {
    if grep -q '^vendor_id[[:space:]]*: GenuineIntel' /proc/cpuinfo 2>/dev/null; then
        printf 'intel-ucode\n'
    elif grep -q '^vendor_id[[:space:]]*: AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
        printf 'amd-ucode\n'
    fi
}

has_nvidia_gpu() {
    command -v lspci >/dev/null 2>&1 || return 1
    lspci -nn 2>/dev/null |
        grep -Eiq '(vga compatible|3d|display) controller.*(nvidia|\[10de:)'
}

gpu_description() {
    command -v lspci >/dev/null 2>&1 || return 0
    lspci -nn 2>/dev/null |
        sed -nE 's/^[0-9a-f:.]+ (VGA compatible controller|3D controller|Display controller)[^:]*: (.*)$/\2/p' |
        paste -sd ';' -
}

# Vulkan drivers for the GPUs present. Steam requires a vulkan-driver and a
# lib32-vulkan-driver provider, so the Mesa path has to name one explicitly.
vulkan_driver_packages() {
    local gpus vendors=() vendor
    gpus=$(lspci -nn 2>/dev/null || true)

    [[ ${gpus} == *"[1002:"* ]] && vendors+=(radeon)
    [[ ${gpus} == *"[8086:"* ]] && vendors+=(intel)
    [[ ${gpus} == *"[10de:"* ]] && vendors+=(nouveau)
    (( ${#vendors[@]} > 0 )) || vendors+=(swrast)

    for vendor in "${vendors[@]}"; do
        printf 'vulkan-%s\nlib32-vulkan-%s\n' "${vendor}" "${vendor}"
    done
}
