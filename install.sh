#!/usr/bin/env bash
#
# Build and install the vfs0090 (Validity 138a:0090 / 138a:0097) libfprint
# driver on RHEL 10 / CentOS Stream 10 family systems, where the stock
# libfprint package ships without it.
#
# See README.md for the full story. Short version: this grafts the
# actively-maintained out-of-tree vfs0090 driver source into an
# exact-version-matched checkout of upstream libfprint, patches two
# small compatibility bugs, and installs the result to /usr/local so it
# never touches the RPM-owned system library. fprintd is then pointed at
# it via a systemd drop-in (LD_LIBRARY_PATH), which is the only system
# file this script modifies outside of /usr/local.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d /tmp/vfs0090-build.XXXXXX)"
PREFIX="${VFS0090_PREFIX:-$HOME/.local/vfs0090}"
LIBDIR="/usr/local/lib64/vfs0090"
UNIT_DROPIN_DIR="/etc/systemd/system/fprintd.service.d"
UNIT_DROPIN="$UNIT_DROPIN_DIR/10-vfs0090-driver.conf"

DRIVER_REPO="https://github.com/3v1n0/libfprint-tod-vfs0090.git"
DRIVER_COMMIT="252c98495791839b36fe5154f55ecca62df2e76a"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

log()  { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] && die "Run this as your normal user, not root. It will call sudo itself where needed."
command -v dnf >/dev/null || die "This script targets RHEL/CentOS Stream (needs dnf)."

# --- 1. Confirm the sensor is actually present -----------------------------
if ! lsusb 2>/dev/null | grep -qE "138a:009[07]"; then
    warn "No Validity 138a:0090 / 138a:0097 sensor detected on the USB bus."
    read -rp "Continue anyway? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || exit 1
fi

# --- 2. Figure out which libfprint version to build against ----------------
if ! rpm -q libfprint >/dev/null 2>&1; then
    die "libfprint isn't installed. Run: sudo dnf install libfprint fprintd fprintd-pam"
fi
LIBFPRINT_VERSION="$(rpm -q --qf '%{VERSION}' libfprint)"
LIBFPRINT_TAG="v${LIBFPRINT_VERSION}"
log "Installed libfprint is ${LIBFPRINT_VERSION}; will build upstream tag ${LIBFPRINT_TAG} to match it exactly."
log "(Building any other version risks an ABI/symbol mismatch with your system's fprintd — see README.)"

# --- 3. Build dependencies ---------------------------------------------------
DEPS=(meson ninja-build gcc pkgconf-pkg-config git glib2-devel libusb1-devel
      nss-devel pixman-devel json-glib-devel gobject-introspection-devel
      libgusb-devel libgudev-devel)
MISSING=()
for pkg in "${DEPS[@]}"; do
    rpm -q "$pkg" >/dev/null 2>&1 || MISSING+=("$pkg")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Installing missing build dependencies: ${MISSING[*]}"
    sudo dnf install -y "${MISSING[@]}"
else
    log "All build dependencies already present."
fi

# --- 4. Fetch sources ---------------------------------------------------------
log "Cloning libfprint ${LIBFPRINT_TAG}..."
git clone --quiet --depth 1 --branch "$LIBFPRINT_TAG" \
    https://gitlab.freedesktop.org/libfprint/libfprint.git "$WORK_DIR/libfprint" \
    || die "No upstream tag ${LIBFPRINT_TAG}. Your libfprint's version has no matching public tag; see README for the manual fallback."

log "Cloning vfs0090 driver source (pinned commit ${DRIVER_COMMIT:0:12})..."
git clone --quiet "$DRIVER_REPO" "$WORK_DIR/driver"
git -C "$WORK_DIR/driver" checkout --quiet "$DRIVER_COMMIT"

mkdir -p "$WORK_DIR/libfprint/libfprint/drivers/vfs0090"
cp "$WORK_DIR/driver/vfs0090.c" "$WORK_DIR/driver/vfs0090.h" \
   "$WORK_DIR/libfprint/libfprint/drivers/vfs0090/"

# --- 5. Apply patches ---------------------------------------------------------
log "Registering vfs0090 with the meson build..."
( cd "$WORK_DIR/libfprint" && patch -p1 < "$REPO_DIR/patches/0001-libfprint-meson-register-vfs0090.patch" ) \
    || die "meson.build patch didn't apply — upstream libfprint's build files changed shape. See README's troubleshooting section."

log "Applying driver compatibility fixes..."
( cd "$WORK_DIR/libfprint/libfprint/drivers/vfs0090" && patch -p1 < "$REPO_DIR/patches/0002-vfs0090-driver-fixes.patch" ) \
    || die "Driver patch didn't apply — the driver source moved on from the pinned commit. See README's troubleshooting section."

# --- 6. Build ------------------------------------------------------------------
log "Configuring build..."
meson setup \
    --prefix="$PREFIX" \
    -Ddrivers=vfs0090 \
    -Dintrospection=false \
    -Ddoc=false \
    -Dudev_rules=disabled \
    -Dudev_hwdb=disabled \
    -Dinstalled-tests=false \
    "$WORK_DIR/libfprint/build" "$WORK_DIR/libfprint"

log "Building (this takes a minute or two)..."
ninja -C "$WORK_DIR/libfprint/build"

log "Verifying the build satisfies every symbol fprintd needs..."
NEEDED="$(objdump -T /usr/libexec/fprintd | awk '/LIBFPRINT_2/{print $NF}' | sort -u)"
PROVIDED="$(nm -D "$WORK_DIR/libfprint/build/libfprint/libfprint-2.so.2.0.0" | awk '$2=="T"{print $3}' | sed 's/@@.*//' | sort -u)"
MISSING_SYMS="$(comm -23 <(echo "$NEEDED") <(echo "$PROVIDED"))"
if [[ -n "$MISSING_SYMS" ]]; then
    die "Built library is missing symbols fprintd needs: $(echo "$MISSING_SYMS" | tr '\n' ' ')
This means the pinned driver commit has drifted from your libfprint version's API. See README's troubleshooting section."
fi
log "Symbol check passed — full ABI match."

ninja -C "$WORK_DIR/libfprint/build" install

# --- 7. Deploy where the sandboxed fprintd can actually read it ---------------
# fprintd's systemd unit has ProtectHome=true, which makes /home invisible to
# it — a build under $HOME won't be reachable via LD_LIBRARY_PATH. /usr/local
# stays readable under ProtectSystem=strict (that only blocks writes), so the
# built library is copied there rather than pointed at directly.
log "Installing built library to $LIBDIR..."
sudo mkdir -p "$LIBDIR"
sudo cp -P "$PREFIX/lib64/libfprint-2.so"* "$LIBDIR/"

log "Pointing fprintd at it via a systemd drop-in..."
sudo mkdir -p "$UNIT_DROPIN_DIR"
printf '[Service]\nEnvironment=LD_LIBRARY_PATH=%s\n' "$LIBDIR" | sudo tee "$UNIT_DROPIN" >/dev/null

sudo systemctl daemon-reload
sudo systemctl restart fprintd

# --- 8. Verify ------------------------------------------------------------------
sleep 1
if fprintd-list "$USER" 2>&1 | grep -q "found 1 devices\|Fingerprints for user"; then
    log "Success — fprintd now sees the sensor."
else
    warn "fprintd restarted but didn't report the device. Run: sudo journalctl -u fprintd -S -1min"
fi

cat <<EOF

Done. Next steps:
  fprintd-enroll -f right-index-finger $USER   # touch the sensor when prompted
  fprintd-verify $USER                          # confirm it recognizes you

If your distro's authselect profile doesn't already have fingerprint auth
enabled:
  sudo authselect enable-feature with-fingerprint

Fingerprint auth then works anywhere PAM's system-auth is used: sudo, the
lock screen, and GDM login.
EOF
