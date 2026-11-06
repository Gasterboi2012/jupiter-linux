#!/usr/bin/env bash
# Jupiter installer - language and keyboard selection.
#
# Both lists are read from the live medium: glibc ships every locale in
# /etc/locale.gen and kbd ships every keymap, so the installer can offer
# exactly what the installed system will be able to use. Nothing is
# hardcoded, which keeps the lists correct on a rolling distribution.

# Overridable so the installer can be exercised by tests without touching
# system paths.
LOCALE_GEN="${JUPITER_LOCALE_GEN:-/etc/locale.gen}"
KEYMAP_ROOT="${JUPITER_KEYMAP_ROOT:-/usr/share/kbd/keymaps}"

# locale_list - every UTF-8 locale the medium knows, in a stable order.
locale_list() {
    [[ -r ${LOCALE_GEN} ]] || return 0
    sed -nE 's/^#?[[:space:]]*([a-z]{2,3}_[A-Z]{2}\.UTF-8)[[:space:]]+UTF-8([[:space:]].*)?$/\1/p' \
        "${LOCALE_GEN}" | sort -u
}

# keymap_list - PC keymaps only (the i386 tree), by basename, because that is
# the name loadkeys(1) and vconsole.conf resolve through their search path.
keymap_list() {
    [[ -d ${KEYMAP_ROOT}/i386 ]] || return 0
    find "${KEYMAP_ROOT}/i386" -name '*.map.gz' -printf '%f\n' 2>/dev/null |
        sed 's/\.map\.gz$//' | sort -u
}

# region_defaults COUNTRY - print "locale|keymap" for a country code.
region_defaults() {
    case ${1:-} in
        AT) printf 'de_AT.UTF-8|de-latin1-nodeadkeys\n' ;;
        AU) printf 'en_AU.UTF-8|us\n' ;;
        BE) printf 'nl_BE.UTF-8|be-latin1\n' ;;
        BR) printf 'pt_BR.UTF-8|br-abnt2\n' ;;
        CA) printf 'en_CA.UTF-8|us\n' ;;
        CH) printf 'de_CH.UTF-8|de_CH-latin1\n' ;;
        CZ) printf 'cs_CZ.UTF-8|cz-lat2\n' ;;
        DE) printf 'de_DE.UTF-8|de-latin1-nodeadkeys\n' ;;
        DK) printf 'da_DK.UTF-8|dk-latin1\n' ;;
        ES) printf 'es_ES.UTF-8|es\n' ;;
        FI) printf 'fi_FI.UTF-8|fi\n' ;;
        FR) printf 'fr_FR.UTF-8|fr-latin9\n' ;;
        GB) printf 'en_GB.UTF-8|uk\n' ;;
        GR) printf 'el_GR.UTF-8|gr\n' ;;
        HU) printf 'hu_HU.UTF-8|hu\n' ;;
        IE) printf 'en_IE.UTF-8|uk\n' ;;
        IL) printf 'he_IL.UTF-8|il\n' ;;
        IS) printf 'is_IS.UTF-8|is-latin1\n' ;;
        IT) printf 'it_IT.UTF-8|it\n' ;;
        JP) printf 'ja_JP.UTF-8|jp106\n' ;;
        # kbd ships no Korean keymap, so Korean users keep the US layout.
        KR) printf 'ko_KR.UTF-8|us\n' ;;
        NL) printf 'nl_NL.UTF-8|us\n' ;;
        NO) printf 'nb_NO.UTF-8|no-latin1\n' ;;
        NZ) printf 'en_NZ.UTF-8|us\n' ;;
        PL) printf 'pl_PL.UTF-8|pl\n' ;;
        PT) printf 'pt_PT.UTF-8|pt-latin1\n' ;;
        RO) printf 'ro_RO.UTF-8|ro\n' ;;
        RU) printf 'ru_RU.UTF-8|ru\n' ;;
        SE) printf 'sv_SE.UTF-8|sv-latin1\n' ;;
        SK) printf 'sk_SK.UTF-8|sk-qwertz\n' ;;
        TR) printf 'tr_TR.UTF-8|tr_q-latin5\n' ;;
        TW) printf 'zh_TW.UTF-8|us\n' ;;
        UA) printf 'uk_UA.UTF-8|ua\n' ;;
        US) printf 'en_US.UTF-8|us\n' ;;
        *) printf 'en_US.UTF-8|us\n' ;;
    esac
}

# suggestion_for_country COUNTRY - print "locale|keymap", falling back to a
# setting the medium actually provides.
suggestion_for_country() {
    local pair locale keymap available

    pair=$(region_defaults "${1:-}")
    locale=${pair%%|*}
    keymap=${pair#*|}

    available=$(locale_list)
    if ! grep -qxF -- "${locale}" <<<"${available}"; then
        locale="en_US.UTF-8"
    fi

    available=$(keymap_list)
    if ! grep -qxF -- "${keymap}" <<<"${available}"; then
        keymap="us"
    fi

    printf '%s|%s\n' "${locale}" "${keymap}"
}

# apply_keymap - load the chosen layout into this console so the password set
# later is typed on the layout the installed system will use.
apply_keymap() {
    # Only touch the console when there is one: the installer also runs from
    # scripts, where this would either fail or hit the wrong terminal.
    if [[ ! -t 0 && ! -t 1 ]]; then
        return 0
    fi
    command -v loadkeys >/dev/null 2>&1 || return 0
    loadkeys "${KEYMAP}" >/dev/null 2>&1 || true
}
