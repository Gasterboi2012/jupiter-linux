#!/usr/bin/env bash
# Jupiter installer - thin, consistent wrappers around dialog.
#
# Every dialog invocation uses --stdout so the selected value arrives on
# stdout and the drawing stays on the terminal. Cancel (or Esc) makes the
# wrapper return 1, which the step functions translate into "go back".

DIALOGRC="${DIALOGRC:-${SCRIPT_DIR}/dialogrc}"
export DIALOGRC

UI_BACKTITLE=" Jupiter"
UI_WIDTH="${UI_WIDTH:-76}"
# Set to 1 before a prompt whose safe answer is "no" (anything destructive);
# the cancel button then has focus, so a stray Enter cannot wipe a disk.
UI_DEFAULT_NO=""

# ui_backtitle STEP TOTAL TITLE
ui_backtitle() {
    UI_BACKTITLE=" Jupiter  ·  ${1}/${2}  ·  ${3}"
}

_ui() {
    dialog --stdout --colors --no-collapse \
        --backtitle "${UI_BACKTITLE}" "$@"
}

# ui_msgbox TITLE TEXT
ui_msgbox() {
    local title=${1} text=${2}
    _ui --title " ${title} " --ok-label "Continue" \
        --msgbox "${text}" 0 "${UI_WIDTH}"
}

# ui_yesno TITLE TEXT [OK_LABEL] [CANCEL_LABEL]
# UI_DEFAULT_NO=1 makes the cancel button the default.
ui_yesno() {
    local title=${1} text=${2} ok=${3:-Yes} cancel=${4:-No}
    local -a extra=()
    if [[ ${UI_DEFAULT_NO} == "1" ]]; then
        extra=(--defaultno)
    fi
    UI_DEFAULT_NO=""
    _ui --title " ${title} " --ok-label "${ok}" --cancel-label "${cancel}" \
        "${extra[@]}" --yesno "${text}" 0 "${UI_WIDTH}"
}

# ui_menu TITLE TEXT TAG DESCRIPTION [TAG DESCRIPTION ...]
# UI_DEFAULT_ITEM may name the tag to preselect.
ui_menu() {
    local title=${1} text=${2}
    shift 2
    local -a extra=()
    if [[ -n ${UI_DEFAULT_ITEM:-} ]]; then
        extra=(--default-item "${UI_DEFAULT_ITEM}")
        UI_DEFAULT_ITEM=""
    fi
    _ui --title " ${title} " --ok-label "Select" --cancel-label "Back" \
        "${extra[@]}" --menu "${text}" 0 "${UI_WIDTH}" 12 "$@"
}

# ui_input TITLE TEXT DEFAULT
ui_input() {
    local title=${1} text=${2} default=${3:-}
    _ui --title " ${title} " --inputbox "${text}" 0 "${UI_WIDTH}" "${default}"
}

# ui_password TITLE TEXT
ui_password() {
    local title=${1} text=${2}
    _ui --title " ${title} " --insecure --passwordbox "${text}" 0 "${UI_WIDTH}"
}

# ui_textbox TITLE FILE - scrollable report, used for failures.
ui_textbox() {
    local title=${1} file=${2}
    _ui --title " ${title} " --scrollbar --ok-label "Close" \
        --textbox "${file}" 0 "${UI_WIDTH}"
}

# ui_infobox TITLE TEXT - fire and forget, used before a slow action.
ui_infobox() {
    local title=${1} text=${2}
    dialog --colors --no-collapse --backtitle "${UI_BACKTITLE}" \
        --title " ${title} " --infobox "${text}" 8 "${UI_WIDTH}"
}

# ui_gauge TITLE TEXT - reads percentages from stdin.
# Esc is disabled as well as the cancel button: dismissing the gauge would
# leave the installation running with no UI and no way back to it.
ui_gauge() {
    local title=${1} text=${2}
    dialog --colors --no-collapse --backtitle "${UI_BACKTITLE}" \
        --title " ${title} " --nocancel --noesc --gauge "${text}" 12 "${UI_WIDTH}" 0
}
