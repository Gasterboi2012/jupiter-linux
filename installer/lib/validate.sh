#!/usr/bin/env bash
# Jupiter installer - input validation.

# valid_username NAME - mirrors useradd(8)'s default naming rules and keeps
# the installer from colliding with accounts the packages create.
valid_username() {
    local name=$1

    [[ ${name} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1

    case ${name} in
        root | bin | daemon | mail | ftp | http | nobody | dbus | polkitd | \
            systemd-* | nvidia-persistenced | _apt | tss | sddm | plasmalogin)
            return 1
            ;;
    esac

    ! getent passwd "${name}" >/dev/null 2>&1
}

# valid_hostname NAME - a single RFC 1123 label.
valid_hostname() {
    local name=$1
    (( ${#name} >= 1 && ${#name} <= 63 )) || return 1
    [[ ${name} =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}
