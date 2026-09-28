#!/usr/bin/env bash
# Reverts install.sh: removes the systemd drop-in and the built library,
# leaving your enrolled fingerprints and the stock RHEL libfprint package
# untouched. fprintd will go back to reporting no supported device for the
# vfs0090 sensor.
set -euo pipefail

LIBDIR="/usr/local/lib64/vfs0090"
UNIT_DROPIN="/etc/systemd/system/fprintd.service.d/10-vfs0090-driver.conf"

log() { printf '\033[1;32m==>\033[0m %s\n' "$1"; }

if [[ -f "$UNIT_DROPIN" ]]; then
    log "Removing systemd drop-in..."
    sudo rm -f "$UNIT_DROPIN"
    sudo rmdir --ignore-fail-on-non-empty "$(dirname "$UNIT_DROPIN")" 2>/dev/null || true
fi

if [[ -d "$LIBDIR" ]]; then
    log "Removing built library from $LIBDIR..."
    sudo rm -rf "$LIBDIR"
fi

log "Reloading systemd and restarting fprintd..."
sudo systemctl daemon-reload
sudo systemctl restart fprintd || true

echo "Done. fprintd is back to the stock RHEL build."
