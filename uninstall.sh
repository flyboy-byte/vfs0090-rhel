#!/usr/bin/env bash
# Reverts install.sh: removes the systemd drop-in and the built library,
# leaving your enrolled fingerprints and the stock RHEL libfprint package
# untouched. fprintd will go back to reporting no supported device for the
# vfs0090 sensor.
set -euo pipefail

LIBDIR="/usr/local/lib64/vfs0090"
DROPIN_DIR="/etc/systemd/system/fprintd.service.d"
UNIT_DROPIN="$DROPIN_DIR/10-vfs0090-driver.conf"
BOOT_DROPIN="$DROPIN_DIR/20-boot-start.conf"

log() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }

if [[ -f "$BOOT_DROPIN" ]]; then
    log "Disabling fprintd boot-start..."
    sudo systemctl disable fprintd 2>/dev/null || true
    sudo rm -f "$BOOT_DROPIN"
fi

if [[ -f "$UNIT_DROPIN" ]]; then
    log "Removing driver systemd drop-in..."
    sudo rm -f "$UNIT_DROPIN"
fi
sudo rmdir --ignore-fail-on-non-empty "$DROPIN_DIR" 2>/dev/null || true

if [[ -d "$LIBDIR" ]]; then
    log "Removing built library from $LIBDIR..."
    sudo rm -rf "$LIBDIR"
fi

log "Reloading systemd and restarting fprintd..."
sudo systemctl daemon-reload
sudo systemctl restart fprintd || true

echo "Done. fprintd is back to the stock RHEL build."
