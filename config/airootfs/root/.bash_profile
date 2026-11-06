# shellcheck shell=bash
# The live medium boots straight into the installer on the first console.
# Leaving the installer drops back to this shell; the installer can then be
# started again with `jupiter-install`.
if [[ -z ${JUPITER_INSTALLER_STARTED:-} ]] && [[ $(tty) == /dev/tty1 ]]; then
    export JUPITER_INSTALLER_STARTED=1
    exec /usr/local/bin/jupiter-install
fi
